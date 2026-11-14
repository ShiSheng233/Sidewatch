/*
 * ProcessProbe.c
 *
 * Narrow, synchronous libproc bridge used by the host snapshot and control
 * paths. Every function returns 0 on success or a positive errno. Field-level
 * failures are reported through the issue callback while the remaining,
 * genuinely readable fields are still delivered.
 *
 * No environment data is ever parsed or emitted. Argument bytes are exposed
 * as the exact argv: argument_count NUL-terminated strings, concatenated, with
 * arguments_length covering the bytes through the final argv NUL and never a
 * following environment byte. All pointers passed to callbacks are borrowed
 * only for the duration of that callback.
 */

#include "ProcessProbe.h"

#include <arpa/inet.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

/* Bounds are checkable limits, never silent truncation points. */
#define SW_MAX_PID_LIST_COUNT 1048576u
#define SW_PID_HEADROOM_COUNT 64u
#define SW_MAX_FD_LIST_BYTES (16u * 1024u * 1024u)
#define SW_FD_HEADROOM_COUNT 32u
#define SW_MAX_ARGS_BYTES (32u * 1024u * 1024u)
#define SW_MAX_ARGUMENT_COUNT 1048576u
#define SW_MAX_ENDPOINT_ROWS 262144u
#define SW_FALLBACK_ARG_MAX (1024u * 1024u)
#define SW_PID_LIST_ATTEMPTS 5u
#define SW_FD_LIST_ATTEMPTS 5u
#define SW_SOCKET_ATTEMPTS 3u
#define SW_ARGS_ATTEMPTS 3u
#define SW_ENDPOINT_INITIAL_ROWS 32u
#define SW_EXECUTABLE_KEY_BYTES 16u /* strlen("executable_path=") */

typedef struct {
    char address[INET6_ADDRSTRLEN];
    SWEndpointInfo info;
} SWEndpointRow;

typedef struct {
    struct proc_fdinfo *primary;
    size_t primary_capacity;
    struct proc_fdinfo *secondary;
    size_t secondary_capacity;
    uint8_t *args;
    size_t args_capacity;
    size_t args_max_bytes;
    SWEndpointRow *endpoints;
    size_t endpoint_capacity;
} SWWorkBuffers;

typedef struct {
    SWProcessCallback process;
    SWEndpointCallback endpoint;
    SWIssueCallback issue;
    void *context;
} SWCallbacks;

static int32_t sw_errno_or(int32_t fallback)
{
    int error = errno;
    return error > 0 ? (int32_t)error : fallback;
}

static int32_t sw_grow_buffer(void **buffer, size_t *capacity, size_t required)
{
    if (required <= *capacity) {
        return 0;
    }

    size_t target = *capacity > 0 ? *capacity : 4096;
    while (target < required) {
        if (target > SIZE_MAX / 2) {
            target = required;
            break;
        }
        target *= 2;
    }

    void *grown = realloc(*buffer, target);
    if (grown == NULL) {
        return ENOMEM;
    }
    *buffer = grown;
    *capacity = target;
    return 0;
}

static void sw_report_issue(const SWCallbacks *callbacks, int32_t pid,
                            SWQueryStage stage, int32_t code)
{
    if (callbacks->issue != NULL && code > 0) {
        callbacks->issue(pid, stage, code, callbacks->context);
    }
}

static int32_t sw_identity_from_bsd(const struct proc_bsdinfo *info, int32_t pid,
                                    SWProcessIdentity *identity)
{
    if (info->pbi_ppid > (uint32_t)INT32_MAX) {
        return EOVERFLOW;
    }
    if (info->pbi_start_tvsec > (uint64_t)(INT64_MAX / 1000000)) {
        return EOVERFLOW;
    }

    int64_t micros = (int64_t)info->pbi_start_tvsec * 1000000;
    if (info->pbi_start_tvusec > (uint64_t)(INT64_MAX - micros)) {
        return EOVERFLOW;
    }
    micros += (int64_t)info->pbi_start_tvusec;

    identity->pid = pid;
    identity->parent_pid = (int32_t)info->pbi_ppid;
    identity->user_id = (uint32_t)info->pbi_uid;
    identity->start_time_micros = micros;
    return 0;
}

static int32_t sw_read_bsd(int32_t pid, struct proc_bsdinfo *info)
{
    memset(info, 0, sizeof(*info));
    errno = 0;
    int bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, (int)sizeof(*info));
    if (bytes <= 0) {
        return sw_errno_or(ESRCH);
    }
    if ((size_t)bytes != sizeof(*info)) {
        return EIO;
    }
    if (info->pbi_pid != (uint32_t)pid) {
        /* The numeric PID no longer names this process instance. */
        return ESRCH;
    }
    return 0;
}

/*
 * Collect the current PID list. Capacity is detected from the sizing call and
 * from the post-call sizing check, so an enumeration is never a partial list
 * presented as complete. Processes appearing after the filled call are outside
 * this capture window; a list that cannot be sized within the bound is EAGAIN.
 */
static int32_t sw_collect_pids(pid_t **buffer, size_t *capacity, size_t *count_out)
{
    *count_out = 0;

    for (unsigned attempt = 0; attempt < SW_PID_LIST_ATTEMPTS; ++attempt) {
        errno = 0;
        int needed = proc_listallpids(NULL, 0);
        if (needed <= 0) {
            return sw_errno_or(EIO);
        }
        if ((uint32_t)needed > SW_MAX_PID_LIST_COUNT) {
            return EOVERFLOW;
        }

        size_t wanted_entries = (size_t)needed + SW_PID_HEADROOM_COUNT;
        if (wanted_entries > SW_MAX_PID_LIST_COUNT) {
            wanted_entries = SW_MAX_PID_LIST_COUNT;
        }
        size_t wanted_bytes = wanted_entries * sizeof(pid_t);

        int32_t error = sw_grow_buffer((void **)buffer, capacity, wanted_bytes);
        if (error != 0) {
            return error;
        }

        errno = 0;
        int filled = proc_listallpids(*buffer, (int)*capacity);
        if (filled <= 0) {
            return sw_errno_or(EIO);
        }

        size_t max_entries = *capacity / sizeof(pid_t);
        size_t got = (size_t)filled;
        if (got > max_entries) {
            got = max_entries;
        }

        errno = 0;
        int after = proc_listallpids(NULL, 0);
        if (after <= 0) {
            return sw_errno_or(EIO);
        }
        if ((uint32_t)after > SW_MAX_PID_LIST_COUNT) {
            return EOVERFLOW;
        }

        if (got >= max_entries || (size_t)after > max_entries) {
            size_t largest = (size_t)after > got ? (size_t)after : got;
            size_t required_entries = largest + SW_PID_HEADROOM_COUNT;
            if (required_entries > SW_MAX_PID_LIST_COUNT) {
                required_entries = SW_MAX_PID_LIST_COUNT;
            }
            size_t required_bytes = required_entries * sizeof(pid_t);
            if (required_bytes <= *capacity) {
                return EOVERFLOW;
            }
            error = sw_grow_buffer((void **)buffer, capacity, required_bytes);
            if (error != 0) {
                return error;
            }
            continue;
        }

        *count_out = got;
        return 0;
    }

    return EAGAIN;
}

static int32_t sw_read_executable(int32_t pid, char *buffer, size_t capacity)
{
    if (capacity < 2) {
        return EINVAL;
    }
    buffer[0] = '\0';
    buffer[capacity - 1] = '\0';

    errno = 0;
    int length = proc_pidpath(pid, buffer, (uint32_t)capacity);
    if (length <= 0) {
        return sw_errno_or(ESRCH);
    }
    if ((size_t)length >= capacity) {
        /* The kernel had to truncate the path into this buffer. */
        buffer[0] = '\0';
        return ENAMETOOLONG;
    }
    if (buffer[0] == '\0') {
        return ENOENT;
    }
    return 0;
}

static int32_t sw_read_cwd(int32_t pid, char *buffer, size_t capacity)
{
    if (capacity < MAXPATHLEN) {
        return EINVAL;
    }

    struct proc_vnodepathinfo info;
    memset(&info, 0, sizeof(info));
    errno = 0;
    int bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info,
                             (int)sizeof(info));
    if (bytes <= 0) {
        return sw_errno_or(ESRCH);
    }
    if ((size_t)bytes != sizeof(info)) {
        return EIO;
    }
    if (info.pvi_cdir.vip_path[MAXPATHLEN - 1] != '\0') {
        return ENAMETOOLONG;
    }
    size_t length = strlen(info.pvi_cdir.vip_path);
    if (length == 0) {
        return ENOENT;
    }
    if (length >= capacity) {
        return ENAMETOOLONG;
    }
    memcpy(buffer, info.pvi_cdir.vip_path, length + 1);
    return 0;
}

/*
 * KERN_PROCARGS2 layout:
 *   int32 argc
 *   bare executable path, NUL-terminated
 *   NUL padding so the prefixed ("executable_path=") first string is padded to
 *     the target's pointer size
 *   argc NUL-terminated argv strings
 *   environment strings (never touched)
 *
 * The padding is computed from the path length and the target pointer size;
 * any NULs beyond that padding are real leading empty arguments. Skipping all
 * padding NULs (the common shortcut) would silently shift argv when argv[0] is
 * empty, so the count is exact here.
 */
static int32_t sw_parse_arguments(const uint8_t *buffer, size_t length,
                                  size_t pointer_size,
                                  const char **arguments_out,
                                  size_t *arguments_length_out,
                                  uint32_t *argument_count_out)
{
    *arguments_out = NULL;
    *arguments_length_out = 0;
    *argument_count_out = 0;

    if (length < sizeof(int32_t)) {
        return EINVAL;
    }

    int32_t argc = 0;
    memcpy(&argc, buffer, sizeof(argc));
    if (argc < 0) {
        return EINVAL;
    }
    if ((uint32_t)argc > SW_MAX_ARGUMENT_COUNT) {
        return EOVERFLOW;
    }

    const uint8_t *cursor = buffer + sizeof(int32_t);
    const uint8_t *end = buffer + length;

    const uint8_t *path_end = memchr(cursor, '\0', (size_t)(end - cursor));
    if (path_end == NULL) {
        return EINVAL;
    }
    size_t path_length = (size_t)(path_end - cursor);

    /* Count the complete NUL run following the executable path. */
    const uint8_t *run_start = path_end + 1;
    const uint8_t *run_cursor = run_start;
    while (run_cursor < end && *run_cursor == '\0') {
        ++run_cursor;
    }
    size_t run_length = (size_t)(run_cursor - run_start);

    if (pointer_size != 4 && pointer_size != 8) {
        return EINVAL;
    }

    size_t padded_length =
        ((path_length + 1 + pointer_size - 1) / pointer_size) * pointer_size;
    size_t padding = padded_length - (path_length + 1);
    if (padding > run_length) {
        /*
         * The observation does not carry the alignment the kernel's layout
         * requires. Refuse it instead of skipping an unknown number of NULs,
         * which could shift argv and consume environment strings.
         */
        return EINVAL;
    }

    if (argc == 0) {
        return 0;
    }

    size_t empty_leading_arguments = run_length - padding;
    if (empty_leading_arguments > (size_t)argc) {
        return EINVAL;
    }

    cursor = run_start + padding;
    if (cursor >= end) {
        return EINVAL;
    }

    const uint8_t *argv_start = cursor;
    for (int32_t index = 0; index < argc; ++index) {
        const uint8_t *terminator = memchr(cursor, '\0', (size_t)(end - cursor));
        if (terminator == NULL) {
            return EINVAL;
        }
        cursor = terminator + 1;
    }

    size_t argv_length = (size_t)(cursor - argv_start);
    if (argv_length == 0) {
        return EINVAL;
    }

    *arguments_out = (const char *)argv_start;
    *arguments_length_out = argv_length;
    *argument_count_out = (uint32_t)argc;
    return 0;
}

static uint32_t sw_process_pointer_size(const struct proc_bsdinfo *info)
{
    return (info->pbi_flags & PROC_FLAG_LP64) != 0 ? 8u : 4u;
}

static int32_t sw_read_arguments(int32_t pid, const struct proc_bsdinfo *bsd,
                                 SWWorkBuffers *work,
                                 const char **arguments_out,
                                 size_t *arguments_length_out,
                                 uint32_t *argument_count_out)
{
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, (int)pid };
    size_t pointer_size = sw_process_pointer_size(bsd);

    *arguments_out = NULL;
    *arguments_length_out = 0;
    *argument_count_out = 0;

    for (unsigned attempt = 0; attempt < SW_ARGS_ATTEMPTS; ++attempt) {
        size_t needed = 0;
        errno = 0;
        if (sysctl(mib, 3, NULL, &needed, NULL, 0) != 0) {
            return sw_errno_or(ESRCH);
        }
        if (needed == 0) {
            return errno != 0 ? sw_errno_or(ESRCH) : 0;
        }
        if (needed > work->args_max_bytes) {
            return EOVERFLOW;
        }

        size_t wanted = needed + 64;
        if (wanted > work->args_max_bytes) {
            wanted = needed;
        }
        int32_t error = sw_grow_buffer((void **)&work->args,
                                       &work->args_capacity, wanted);
        if (error != 0) {
            return error;
        }

        size_t actual = work->args_capacity;
        errno = 0;
        if (sysctl(mib, 3, work->args, &actual, NULL, 0) != 0) {
            int saved = errno;
            if (saved == ENOMEM) {
                size_t required = actual > work->args_capacity
                    ? actual
                    : work->args_capacity + 4096;
                if (required <= work->args_capacity) {
                    required = work->args_capacity * 2;
                }
                if (required > work->args_max_bytes) {
                    return EOVERFLOW;
                }
                error = sw_grow_buffer((void **)&work->args,
                                       &work->args_capacity, required);
                if (error != 0) {
                    return error;
                }
                continue;
            }
            errno = saved;
            return sw_errno_or(ESRCH);
        }

        if (actual >= work->args_capacity) {
            /* The kernel may report a larger requirement or a full buffer;
             * either way grow and retry rather than parsing a truncated view. */
            size_t required = actual > work->args_capacity
                ? actual
                : work->args_capacity;
            if (required > work->args_max_bytes) {
                return EOVERFLOW;
            }
            if (required <= work->args_capacity) {
                required = work->args_capacity * 2;
            }
            if (required <= work->args_capacity) {
                return EOVERFLOW;
            }
            if (required > work->args_max_bytes) {
                required = work->args_max_bytes;
            }
            if (required <= work->args_capacity) {
                return EOVERFLOW;
            }
            error = sw_grow_buffer((void **)&work->args,
                                   &work->args_capacity, required);
            if (error != 0) {
                return error;
            }
            continue;
        }

        if (actual == 0) {
            return 0;
        }
        return sw_parse_arguments(work->args, actual, pointer_size,
                                  arguments_out, arguments_length_out,
                                  argument_count_out);
    }

    return EAGAIN;
}

/*
 * Read one exact FD list. The returned byte count is only produced once the
 * list fits without filling the buffer and a re-size check confirms the list
 * has not grown past the buffer.
 */
static int32_t sw_read_fd_list(int32_t pid, struct proc_fdinfo **buffer,
                               size_t *capacity, size_t *bytes_out)
{
    *bytes_out = 0;

    for (unsigned attempt = 0; attempt < SW_FD_LIST_ATTEMPTS; ++attempt) {
        errno = 0;
        int needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (needed < 0) {
            return sw_errno_or(ESRCH);
        }
        if (needed == 0) {
            return errno != 0 ? sw_errno_or(ESRCH) : 0;
        }
        if ((size_t)needed > SW_MAX_FD_LIST_BYTES) {
            return EOVERFLOW;
        }
        if ((size_t)needed % sizeof(struct proc_fdinfo) != 0) {
            return EIO;
        }

        size_t wanted_bytes = (size_t)needed +
            SW_FD_HEADROOM_COUNT * sizeof(struct proc_fdinfo);
        if (wanted_bytes > SW_MAX_FD_LIST_BYTES) {
            wanted_bytes = (size_t)needed;
        }
        int32_t error = sw_grow_buffer((void **)buffer, capacity, wanted_bytes);
        if (error != 0) {
            return error;
        }

        errno = 0;
        int filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, *buffer,
                                  (int)*capacity);
        if (filled < 0) {
            return sw_errno_or(ESRCH);
        }
        if (filled == 0) {
            return errno != 0 ? sw_errno_or(ESRCH) : 0;
        }
        if ((size_t)filled > *capacity) {
            return EIO;
        }
        if ((size_t)filled % sizeof(struct proc_fdinfo) != 0) {
            return EIO;
        }

        errno = 0;
        int after = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (after < 0 || (after == 0 && errno != 0)) {
            return sw_errno_or(ESRCH);
        }

        /* proc_pidfdlist caps its iteration at capacity / sizeof(entry), so a
         * byte comparison would miss truncation when the capacity is not an
         * exact multiple of the entry size. */
        size_t max_entries = *capacity / sizeof(struct proc_fdinfo);
        size_t filled_entries = (size_t)filled / sizeof(struct proc_fdinfo);
        bool filled_buffer = filled_entries >= max_entries;
        bool grew_past_buffer = (size_t)after > *capacity;
        if (filled_buffer || grew_past_buffer) {
            size_t largest = (size_t)after > (size_t)filled
                ? (size_t)after
                : (size_t)filled;
            size_t required = largest +
                SW_FD_HEADROOM_COUNT * sizeof(struct proc_fdinfo);
            if (required > SW_MAX_FD_LIST_BYTES) {
                if (largest > SW_MAX_FD_LIST_BYTES) {
                    return EOVERFLOW;
                }
                required = largest;
            }
            if (required <= *capacity) {
                return EOVERFLOW;
            }
            error = sw_grow_buffer((void **)buffer, capacity, required);
            if (error != 0) {
                return error;
            }
            continue;
        }

        *bytes_out = (size_t)filled;
        return 0;
    }

    return EAGAIN;
}

static int32_t sw_append_endpoint(SWEndpointRow **rows, size_t *capacity,
                                  size_t *count, const SWEndpointRow *row)
{
    if (*count >= SW_MAX_ENDPOINT_ROWS) {
        return EOVERFLOW;
    }
    if (*count == *capacity) {
        size_t target = *capacity > 0 ? *capacity * 2 : SW_ENDPOINT_INITIAL_ROWS;
        if (target > SW_MAX_ENDPOINT_ROWS) {
            target = SW_MAX_ENDPOINT_ROWS;
        }
        if (target <= *capacity) {
            return EOVERFLOW;
        }
        SWEndpointRow *grown = realloc(*rows, target * sizeof(SWEndpointRow));
        if (grown == NULL) {
            return ENOMEM;
        }
        *rows = grown;
        *capacity = target;
    }
    (*rows)[*count] = *row;
    (*count)++;
    return 0;
}

static int32_t sw_inspect_socket_fd(int32_t pid, int fd,
                                    SWEndpointRow *row, bool *is_endpoint)
{
    *is_endpoint = false;

    struct socket_fdinfo info;
    memset(&info, 0, sizeof(info));
    errno = 0;
    int bytes = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info,
                               (int)sizeof(info));
    if (bytes <= 0) {
        return sw_errno_or(EBADF);
    }
    if ((size_t)bytes != sizeof(info)) {
        return EIO;
    }

    int family = info.psi.soi_family;
    if (family != AF_INET && family != AF_INET6) {
        return 0;
    }

    const struct in_sockinfo *internet = NULL;
    int transport = 0;

    if (info.psi.soi_kind == SOCKINFO_TCP &&
        info.psi.soi_protocol == IPPROTO_TCP &&
        info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN) {
        internet = &info.psi.soi_proto.pri_tcp.tcpsi_ini;
        transport = IPPROTO_TCP;
    } else if (info.psi.soi_kind == SOCKINFO_IN &&
               info.psi.soi_protocol == IPPROTO_UDP) {
        internet = &info.psi.soi_proto.pri_in;
        transport = IPPROTO_UDP;
    } else {
        return 0;
    }

    uint16_t port = ntohs((uint16_t)internet->insi_lport);
    if (port == 0) {
        /* TCP listeners cannot have port 0; UDP sockets with port 0 are
         * unbound and are not endpoints. */
        return 0;
    }

    char address[INET6_ADDRSTRLEN];
    address[0] = '\0';
    uint32_t scope_id = 0;

    /*
     * The kernel copies the inpcb local-address union into ina_6 in full for
     * both families. For AF_INET the IPv4 address occupies the last four bytes
     * (in4in6_addr), while AF_INET6 carries the complete 16-byte address.
     */
    if (family == AF_INET) {
        if (inet_ntop(AF_INET, &internet->insi_laddr.ina_46.i46a_addr4,
                      address, sizeof(address)) == NULL) {
            return sw_errno_or(EIO);
        }
    } else {
        struct in6_addr local = internet->insi_laddr.ina_6;
        scope_id = (uint32_t)internet->insi_v6.in6_ifindex;
        /* Darwin embeds a scoped address's interface in its second word.
         * Recover it exactly as the kernel's getsockname path does. */
        if (IN6_IS_ADDR_LINKLOCAL(&local) || IN6_IS_ADDR_MC_LINKLOCAL(&local)) {
            uint32_t embedded_scope = ((uint32_t)local.s6_addr[2] << 8) | local.s6_addr[3];
            if (scope_id && embedded_scope && scope_id != embedded_scope) return EIO;
            if (!scope_id) scope_id = embedded_scope;
            local.s6_addr[2] = local.s6_addr[3] = 0;
        }
        if (inet_ntop(AF_INET6, &local, address, sizeof(address)) == NULL) {
            return sw_errno_or(EIO);
        }
    }

    memset(row, 0, sizeof(*row));
    size_t address_length = strlen(address);
    if (address_length >= sizeof(row->address)) {
        return EOVERFLOW;
    }
    memcpy(row->address, address, address_length + 1);
    /* The pointer is attached immediately before the callback, after any
     * possible row-vector reallocation. */
    row->info.address = NULL;
    row->info.address_family = family;
    row->info.transport = transport;
    row->info.scope_id = scope_id;
    row->info.port = port;
    *is_endpoint = true;
    return 0;
}

static void sw_scan_fd_list(int32_t pid, const struct proc_fdinfo *fds,
                            size_t bytes, SWEndpointRow **rows,
                            size_t *row_capacity, size_t *row_count,
                            bool *complete, int32_t *first_error)
{
    *complete = true;
    *first_error = 0;
    *row_count = 0;

    if (bytes % sizeof(struct proc_fdinfo) != 0) {
        *complete = false;
        *first_error = EIO;
        return;
    }

    size_t count = bytes / sizeof(struct proc_fdinfo);
    for (size_t index = 0; index < count; ++index) {
        if (fds[index].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }
        if (fds[index].proc_fd < 0) {
            *complete = false;
            if (*first_error == 0) {
                *first_error = EBADF;
            }
            continue;
        }

        SWEndpointRow row;
        bool is_endpoint = false;
        int32_t error = sw_inspect_socket_fd(pid, fds[index].proc_fd, &row,
                                             &is_endpoint);
        if (error != 0) {
            *complete = false;
            if (*first_error == 0) {
                *first_error = error;
            }
            continue;
        }
        if (!is_endpoint) {
            continue;
        }

        error = sw_append_endpoint(rows, row_capacity, row_count, &row);
        if (error != 0) {
            *complete = false;
            if (*first_error == 0) {
                *first_error = error;
            }
            return;
        }
    }
}

/*
 * Scan all socket FDs, retrying when the FD list changes during the scan.
 * Rows are accumulated in the reusable vector and are only reported by the
 * caller, after the process identity has been rechecked.
 */
static int32_t sw_collect_sockets(int32_t pid, SWWorkBuffers *work,
                                  size_t *endpoint_count_out,
                                  bool *sockets_complete_out)
{
    int32_t reported_error = 0;
    bool reported_complete = false;
    size_t reported_count = 0;

    for (unsigned attempt = 0; attempt < SW_SOCKET_ATTEMPTS; ++attempt) {
        size_t bytes = 0;
        int32_t error = sw_read_fd_list(pid, &work->primary,
                                        &work->primary_capacity, &bytes);
        if (error != 0) {
            reported_error = error;
            reported_complete = false;
            reported_count = 0;
            break;
        }

        size_t count = 0;
        bool complete = true;
        int32_t first_error = 0;
        sw_scan_fd_list(pid, work->primary, bytes,
                        &work->endpoints, &work->endpoint_capacity,
                        &count, &complete, &first_error);

        size_t verify_bytes = 0;
        error = sw_read_fd_list(pid, &work->secondary,
                                &work->secondary_capacity, &verify_bytes);
        if (error != 0) {
            reported_error = error;
            reported_complete = false;
            reported_count = count;
            break;
        }

        bool stable = verify_bytes == bytes &&
            (bytes == 0 ||
             memcmp(work->primary, work->secondary, bytes) == 0);

        reported_count = count;
        if (stable) {
            reported_complete = complete;
            reported_error = first_error;
            break;
        }

        reported_complete = false;
        reported_error = first_error != 0 ? first_error : EAGAIN;
        /* An unstable list is retried; the next pass replaces the rows. */
    }

    *endpoint_count_out = reported_count;
    *sockets_complete_out = reported_complete;
    return reported_error;
}

static void sw_process_pid(int32_t pid, SWWorkBuffers *work,
                           const SWCallbacks *callbacks)
{
    struct proc_bsdinfo before;
    int32_t error = sw_read_bsd(pid, &before);
    if (error != 0) {
        if (error != ESRCH) {
            sw_report_issue(callbacks, pid, SW_QUERY_IDENTITY, error);
        }
        return;
    }
    if (before.pbi_status == SZOMB) {
        return;
    }

    char executable[PROC_PIDPATHINFO_MAXSIZE];
    bool executable_ok = false;
    error = sw_read_executable(pid, executable, sizeof(executable));
    if (error == 0) {
        executable_ok = true;
    } else {
        sw_report_issue(callbacks, pid, SW_QUERY_EXECUTABLE, error);
    }

    char working_directory[MAXPATHLEN];
    working_directory[0] = '\0';
    bool cwd_ok = false;
    error = sw_read_cwd(pid, working_directory, sizeof(working_directory));
    if (error == 0) {
        cwd_ok = true;
    } else {
        sw_report_issue(callbacks, pid, SW_QUERY_CWD, error);
    }

    const char *arguments = NULL;
    size_t arguments_length = 0;
    uint32_t argument_count = 0;
    error = sw_read_arguments(pid, &before, work, &arguments,
                              &arguments_length, &argument_count);
    if (error != 0) {
        arguments = NULL;
        arguments_length = 0;
        argument_count = 0;
        sw_report_issue(callbacks, pid, SW_QUERY_ARGUMENTS, error);
    }

    bool sockets_complete = false;
    size_t endpoint_count = 0;
    if (callbacks->endpoint != NULL) {
        error = sw_collect_sockets(pid, work, &endpoint_count,
                                   &sockets_complete);
        if (error != 0) {
            sockets_complete = false;
            sw_report_issue(callbacks, pid, SW_QUERY_SOCKETS, error);
        }
    }

    struct proc_bsdinfo after;
    error = sw_read_bsd(pid, &after);
    if (error != 0) {
        if (error != ESRCH) {
            sw_report_issue(callbacks, pid, SW_QUERY_IDENTITY, error);
        }
        return;
    }
    if (after.pbi_status == SZOMB) {
        return;
    }
    if (after.pbi_start_tvsec != before.pbi_start_tvsec ||
        after.pbi_start_tvusec != before.pbi_start_tvusec) {
        /* The PID was reused while it was being inspected. */
        sw_report_issue(callbacks, pid, SW_QUERY_IDENTITY, ESTALE);
        return;
    }

    SWProcessIdentity identity;
    error = sw_identity_from_bsd(&after, pid, &identity);
    if (error != 0) {
        sw_report_issue(callbacks, pid, SW_QUERY_IDENTITY, error);
        return;
    }

    SWProcessInfo process_info;
    memset(&process_info, 0, sizeof(process_info));
    process_info.identity = identity;
    process_info.executable = executable_ok ? executable : "";
    process_info.working_directory = cwd_ok ? working_directory : NULL;
    process_info.arguments = arguments;
    process_info.arguments_length = arguments_length;
    process_info.argument_count = argument_count;
    process_info.sockets_complete = sockets_complete;

    callbacks->process(&process_info, callbacks->context);

    if (callbacks->endpoint != NULL) {
        for (size_t index = 0; index < endpoint_count; ++index) {
            SWEndpointRow *row = &work->endpoints[index];
            row->info.process = identity;
            row->info.address = row->address;
            callbacks->endpoint(&row->info, callbacks->context);
        }
    }
}

static size_t sw_argument_buffer_limit(void)
{
    int argmax = 0;
    size_t length = sizeof(argmax);
    int mib[2] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(mib, 2, &argmax, &length, NULL, 0) != 0 || argmax <= 0) {
        argmax = (int)SW_FALLBACK_ARG_MAX;
    }

    size_t limit = (size_t)argmax + SW_EXECUTABLE_KEY_BYTES +
                   4u * MAXPATHLEN + 64u;
    if (limit > SW_MAX_ARGS_BYTES) {
        limit = SW_MAX_ARGS_BYTES;
    }
    if (limit < 64) {
        limit = 64;
    }
    return limit;
}

int32_t sw_probe_capture(SWProcessCallback process, SWEndpointCallback endpoint,
                         SWIssueCallback issue, void *context)
{
    if (process == NULL) {
        return EINVAL;
    }

    SWCallbacks callbacks = {
        .process = process,
        .endpoint = endpoint,
        .issue = issue,
        .context = context,
    };

    SWWorkBuffers work;
    memset(&work, 0, sizeof(work));
    work.args_max_bytes = sw_argument_buffer_limit();

    pid_t *pids = NULL;
    size_t pid_capacity = 0;
    size_t pid_count = 0;

    int32_t error = sw_collect_pids(&pids, &pid_capacity, &pid_count);
    if (error == 0) {
        for (size_t index = 0; index < pid_count; ++index) {
            pid_t pid = pids[index];
            if (pid <= 0) {
                continue;
            }
            sw_process_pid((int32_t)pid, &work, &callbacks);
        }
    }

    free(pids);
    free(work.primary);
    free(work.secondary);
    free(work.args);
    free(work.endpoints);
    return error;
}

int32_t sw_probe_identity(int32_t pid, SWProcessIdentity *identity)
{
    if (pid <= 0 || identity == NULL) {
        return EINVAL;
    }

    struct proc_bsdinfo info;
    int32_t error = sw_read_bsd(pid, &info);
    if (error != 0) {
        return error;
    }
    /* PROC_PIDTBSDINFO is requested without the zombie-reference argument, so
     * a vanished process reports ESRCH instead of a stale zombie record. */
    return sw_identity_from_bsd(&info, pid, identity);
}

int32_t sw_probe_signal(int32_t pid, int64_t start_time_micros,
                        uint32_t version, uint32_t user_id,
                        const uint8_t *token, size_t token_length,
                        int32_t signal_number)
{
    if (pid <= 0 || pid == (int32_t)getpid()) {
        return EINVAL;
    }
    if (signal_number != SIGTERM && signal_number != SIGKILL) {
        return EINVAL;
    }
    if (token == NULL || token_length != sizeof(audit_token_t)) {
        return EINVAL;
    }

    audit_token_t audit_token;
    memcpy(&audit_token, token, sizeof(audit_token));

    if ((int32_t)audit_token_to_pid(audit_token) != pid) {
        return EINVAL;
    }
    if ((uint32_t)audit_token_to_pidversion(audit_token) != version) {
        /* The supplied execution identity is not the token's execution. */
        return ESTALE;
    }
    if ((uint32_t)audit_token_to_euid(audit_token) != user_id) {
        return EPERM;
    }
    if ((uint32_t)geteuid() != user_id) {
        return EPERM;
    }

    struct proc_bsdinfo info;
    int32_t error = sw_read_bsd(pid, &info);
    if (error != 0) {
        return error;
    }
    if (info.pbi_status == SZOMB) {
        return ESRCH;
    }
    if ((uint32_t)info.pbi_uid != user_id) {
        return EPERM;
    }

    SWProcessIdentity identity;
    error = sw_identity_from_bsd(&info, pid, &identity);
    if (error != 0) {
        return error;
    }
    if (identity.start_time_micros != start_time_micros) {
        return ESTALE;
    }

    errno = 0;
    int result = proc_signal_with_audittoken(&audit_token, (int)signal_number);
    if (result == 0) {
        return 0;
    }
    if (result > 0) {
        return (int32_t)result;
    }
    return sw_errno_or(EIO);
}

int32_t sw_probe_self_token(uint8_t *token, size_t token_length)
{
    if (token == NULL || token_length != sizeof(audit_token_t)) {
        return EINVAL;
    }

    audit_token_t audit_token;
    memset(&audit_token, 0, sizeof(audit_token));
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_AUDIT_TOKEN,
                                     (task_info_t)&audit_token, &count);
    if (result != KERN_SUCCESS) {
        switch (result) {
        case KERN_PROTECTION_FAILURE:
            return EPERM;
        case KERN_INVALID_ARGUMENT:
            return EINVAL;
        default:
            return EIO;
        }
    }
    if (count != TASK_AUDIT_TOKEN_COUNT) {
        return EIO;
    }

    memcpy(token, &audit_token, sizeof(audit_token));
    return 0;
}

int32_t sw_probe_session_writers(SWSessionWriterCallback writer, void *context)
{
    if (writer == NULL) return EINVAL;
    pid_t *pids = NULL;
    size_t pid_capacity = 0, pid_count = 0;
    struct proc_fdinfo *fds = NULL;
    size_t fd_capacity = 0;
    int32_t result = sw_collect_pids(&pids, &pid_capacity, &pid_count);
    if (result != 0) { free(pids); return result; }

    for (size_t index = 0; index < pid_count; ++index) {
        SWProcessIdentity before;
        if (sw_probe_identity(pids[index], &before) != 0 || before.user_id != getuid()) continue;
        size_t fd_bytes = 0;
        if (sw_read_fd_list(before.pid, &fds, &fd_capacity, &fd_bytes) != 0) continue;
        size_t fd_count = fd_bytes / sizeof(*fds);
        for (size_t fd_index = 0; fd_index < fd_count; ++fd_index) {
            if (fds[fd_index].proc_fdtype != PROX_FDTYPE_VNODE) continue;
            struct vnode_fdinfowithpath info;
            memset(&info, 0, sizeof(info));
            int bytes = proc_pidfdinfo(before.pid, fds[fd_index].proc_fd,
                                      PROC_PIDFDVNODEPATHINFO, &info, (int)sizeof(info));
            if (bytes != (int)sizeof(info)) continue;
            /* proc_fileinfo exports kernel FWRITE (0x2), not user O_WRONLY. */
            if ((info.pfi.fi_openflags & 0x2u) == 0) continue;
            size_t length = strnlen(info.pvip.vip_path, sizeof(info.pvip.vip_path));
            if (length < 6 || length == sizeof(info.pvip.vip_path) ||
                memcmp(info.pvip.vip_path + length - 6, ".jsonl", 6) != 0) continue;
            SWProcessIdentity after;
            if (sw_probe_identity(before.pid, &after) != 0 ||
                after.start_time_micros != before.start_time_micros ||
                after.user_id != before.user_id) continue;
            writer(&before, info.pvip.vip_path, context);
        }
    }
    free(fds);
    free(pids);
    return 0;
}
