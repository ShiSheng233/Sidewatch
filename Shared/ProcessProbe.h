#ifndef SIDEWATCH_PROCESS_PROBE_H
#define SIDEWATCH_PROCESS_PROBE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef enum {
    SW_QUERY_ENUMERATION = 1,
    SW_QUERY_IDENTITY = 2,
    SW_QUERY_EXECUTABLE = 3,
    SW_QUERY_ARGUMENTS = 4,
    SW_QUERY_CWD = 5,
    SW_QUERY_SOCKETS = 6
} SWQueryStage;

typedef struct {
    int32_t pid;
    int32_t parent_pid;
    uint32_t user_id;
    int64_t start_time_micros;
} SWProcessIdentity;

typedef struct {
    SWProcessIdentity identity;
    const char *executable;
    const char *working_directory;
    const char *arguments;
    size_t arguments_length;
    uint32_t argument_count;
    bool sockets_complete;
} SWProcessInfo;

typedef struct {
    SWProcessIdentity process;
    int32_t address_family;
    int32_t transport; /* IPPROTO_TCP or IPPROTO_UDP */
    const char *address;
    uint32_t scope_id;
    uint16_t port;
} SWEndpointInfo;

typedef void (*SWProcessCallback)(const SWProcessInfo *info, void *context);
typedef void (*SWEndpointCallback)(const SWEndpointInfo *info, void *context);
typedef void (*SWIssueCallback)(int32_t pid, SWQueryStage stage, int32_t code, void *context);

/* Synchronous callbacks; all callback pointers are borrowed until callback return. */
int32_t sw_probe_capture(SWProcessCallback process, SWEndpointCallback endpoint,
                         SWIssueCallback issue, void *context);
int32_t sw_probe_identity(int32_t pid, SWProcessIdentity *identity);
int32_t sw_probe_signal(int32_t pid, int64_t start_time_micros, uint32_t version,
                       uint32_t user_id, const uint8_t *token, size_t token_length,
                       int32_t signal_number);
int32_t sw_probe_self_token(uint8_t *token, size_t token_length);

#endif
