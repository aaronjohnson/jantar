/*
 * npu_port: Intel NPU hardware counters from Level Zero, run as an Erlang Port.
 *
 * The BEAM writes requests to our stdin and reads replies from our stdout,
 * each framed by a 4-byte big-endian length ({packet, 4}), as with
 * cairo_port. A crash here only ends this process.
 *
 * Any Level Zero call wakes a suspended NPU, even zeInit, so nothing is
 * initialised until OPEN, and jantar sends OPEN only while the NPU is
 * already awake for real work; CLOSE lets it sleep again.
 *
 * Requests (first byte is the command; integers little-endian):
 *   1 OPEN    group names, comma separated ("NOC,FREQ")
 *             -> groups:u16, then per group: len:u16 name, metrics:u16,
 *                then len:u16 name for each metric
 *   2 READ    -> per opened group: reports:u32, then metrics x f64, the
 *                values of the newest report (zeros when reports is 0)
 *   3 CLOSE   close the streamers and the context
 *   4 ECHO    any bytes -> the same bytes
 * Replies: 0 then the results, or 1 then an error message.
 *
 * Streamer reports come every 100 ms while the NPU is busy. NOC and FRC
 * metrics are free-running cumulative counters (diff two READs for a rate);
 * FREQ metrics are the clock at the time of the report.
 *
 * Needs ZET_ENABLE_METRICS=1 in the environment, and the driver
 * (libze_intel_npu) on the loader's path: on NixOS,
 * LD_LIBRARY_PATH=/run/opengl-driver/lib.
 *
 *   npu_port --watch NOC,FREQ   prints each READ once a second, for testing
 */
#include <level_zero/ze_api.h>
#include <level_zero/zet_api.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_GROUPS 4
#define SAMPLING_NS 100000000u

/* ---------------------------------------------------------------- I/O */

static int read_exact(void *buf, size_t n) {
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = read(0, p, n);
        if (r <= 0) return -1; /* EOF: the BEAM closed the port */
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static void write_exact(const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = write(1, p, n);
        if (w <= 0) exit(1);
        p += w;
        n -= (size_t)w;
    }
}

static void reply(const void *data, uint32_t len) {
    uint8_t head[4] = {len >> 24, len >> 16, len >> 8, len};
    write_exact(head, 4);
    write_exact(data, len);
}

/* A growing reply buffer; byte 0 is the status. */
typedef struct {
    uint8_t *data;
    size_t len, cap;
} out;

static void put(out *o, const void *p, size_t n) {
    if (o->len + n > o->cap) {
        o->cap = (o->len + n) * 2;
        o->data = realloc(o->data, o->cap);
    }
    memcpy(o->data + o->len, p, n);
    o->len += n;
}

static void put_u16(out *o, uint16_t v) { put(o, (uint8_t[]){v, v >> 8}, 2); }

static void put_u32(out *o, uint32_t v) { put(o, (uint8_t[]){v, v >> 8, v >> 16, v >> 24}, 4); }

static void put_f64(out *o, double v) {
    uint64_t b;
    memcpy(&b, &v, 8);
    for (int i = 0; i < 8; i++) put(o, (uint8_t[]){b >> (8 * i)}, 1);
}

static void put_str16(out *o, const char *s) {
    size_t n = strlen(s);
    put_u16(o, (uint16_t)n);
    put(o, s, n);
}

static out ok_reply(void) {
    out o = {0};
    put(&o, (uint8_t[]){0}, 1);
    return o;
}

static void send_out(out *o) {
    reply(o->data, (uint32_t)o->len);
    free(o->data);
}

static void reply_error(const char *fmt, ...) {
    char msg[512];
    msg[0] = 1;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(msg + 1, sizeof msg - 1, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    if (n > (int)sizeof msg - 2) n = sizeof msg - 2;
    reply(msg, (uint32_t)n + 1);
}

/* ---------------------------------------------------------------- Level Zero */

typedef struct {
    char name[ZET_MAX_METRIC_GROUP_NAME];
    zet_metric_group_handle_t group;
    zet_metric_streamer_handle_t streamer;
    uint32_t metrics;
    char (*metric_names)[ZET_MAX_METRIC_NAME];
} group;

static int inited;
static ze_driver_handle_t driver;
static ze_device_handle_t device;
static ze_context_handle_t context;
static group groups[MAX_GROUPS];
static uint32_t ngroups;
static uint8_t *raw;
static size_t raw_cap;

static ze_result_t find_npu(void) {
    uint32_t nd = 0;
    ze_result_t r = zeDriverGet(&nd, NULL);
    if (r) return r;
    ze_driver_handle_t drivers[8];
    if (nd > 8) nd = 8;
    if ((r = zeDriverGet(&nd, drivers))) return r;
    for (uint32_t d = 0; d < nd; d++) {
        uint32_t n = 0;
        if (zeDeviceGet(drivers[d], &n, NULL) || n == 0) continue;
        ze_device_handle_t devs[8];
        if (n > 8) n = 8;
        if (zeDeviceGet(drivers[d], &n, devs)) continue;
        for (uint32_t i = 0; i < n; i++) {
            ze_device_properties_t p = {.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
            if (zeDeviceGetProperties(devs[i], &p) == ZE_RESULT_SUCCESS && p.type == ZE_DEVICE_TYPE_VPU) {
                driver = drivers[d];
                device = devs[i];
                return ZE_RESULT_SUCCESS;
            }
        }
    }
    return ZE_RESULT_ERROR_DEVICE_LOST;
}

static zet_metric_group_handle_t find_group(const char *name) {
    uint32_t n = 0;
    if (zetMetricGroupGet(device, &n, NULL) || n == 0) return NULL;
    zet_metric_group_handle_t *all = calloc(n, sizeof *all);
    zet_metric_group_handle_t found = NULL;
    if (zetMetricGroupGet(device, &n, all) == ZE_RESULT_SUCCESS) {
        for (uint32_t i = 0; i < n && !found; i++) {
            zet_metric_group_properties_t p = {.stype = ZET_STRUCTURE_TYPE_METRIC_GROUP_PROPERTIES};
            if (zetMetricGroupGetProperties(all[i], &p) == ZE_RESULT_SUCCESS && strcmp(p.name, name) == 0)
                found = all[i];
        }
    }
    free(all);
    return found;
}

static void close_all(void) {
    for (uint32_t g = 0; g < ngroups; g++) {
        if (groups[g].streamer) zetMetricStreamerClose(groups[g].streamer);
        free(groups[g].metric_names);
    }
    if (context) {
        zetContextActivateMetricGroups(context, device, 0, NULL);
        zeContextDestroy(context);
    }
    memset(groups, 0, sizeof groups);
    ngroups = 0;
    context = NULL;
}

/* Returns NULL, or what went wrong (and everything is closed again). */
static const char *open_groups(char *names) {
    static char why[160];
    if (context) close_all();
    ze_result_t r;
    if (!inited) {
        if ((r = zeInit(ZE_INIT_FLAG_VPU_ONLY))) {
            snprintf(why, sizeof why, "zeInit: 0x%x", r);
            return why;
        }
        if ((r = find_npu())) {
            snprintf(why, sizeof why, "no NPU device (0x%x)", r);
            return why;
        }
        inited = 1;
    }
    ze_context_desc_t cd = {.stype = ZE_STRUCTURE_TYPE_CONTEXT_DESC};
    if ((r = zeContextCreate(driver, &cd, &context))) {
        context = NULL;
        snprintf(why, sizeof why, "zeContextCreate: 0x%x", r);
        return why;
    }

    zet_metric_group_handle_t handles[MAX_GROUPS];
    for (char *save = NULL, *name = strtok_r(names, ",", &save); name; name = strtok_r(NULL, ",", &save)) {
        if (ngroups == MAX_GROUPS) break;
        group *g = &groups[ngroups];
        if (!(g->group = find_group(name))) {
            snprintf(why, sizeof why, "no metric group %s", name);
            close_all();
            return why;
        }
        snprintf(g->name, sizeof g->name, "%s", name);
        zet_metric_group_properties_t p = {.stype = ZET_STRUCTURE_TYPE_METRIC_GROUP_PROPERTIES};
        zetMetricGroupGetProperties(g->group, &p);
        g->metrics = p.metricCount;
        g->metric_names = calloc(g->metrics ? g->metrics : 1, sizeof *g->metric_names);
        zet_metric_handle_t *ms = calloc(g->metrics ? g->metrics : 1, sizeof *ms);
        uint32_t n = g->metrics;
        zetMetricGet(g->group, &n, ms);
        for (uint32_t m = 0; m < n; m++) {
            zet_metric_properties_t mp = {.stype = ZET_STRUCTURE_TYPE_METRIC_PROPERTIES};
            zetMetricGetProperties(ms[m], &mp);
            snprintf(g->metric_names[m], ZET_MAX_METRIC_NAME, "%s", mp.name);
        }
        free(ms);
        handles[ngroups++] = g->group;
    }

    if ((r = zetContextActivateMetricGroups(context, device, ngroups, handles))) {
        snprintf(why, sizeof why, "zetContextActivateMetricGroups: 0x%x", r);
        close_all();
        return why;
    }
    for (uint32_t i = 0; i < ngroups; i++) {
        zet_metric_streamer_desc_t sd = {
            .stype = ZET_STRUCTURE_TYPE_METRIC_STREAMER_DESC,
            .notifyEveryNReports = 100,
            .samplingPeriod = SAMPLING_NS,
        };
        if ((r = zetMetricStreamerOpen(context, device, groups[i].group, &sd, NULL, &groups[i].streamer))) {
            groups[i].streamer = NULL;
            snprintf(why, sizeof why, "zetMetricStreamerOpen %s: 0x%x", groups[i].name, r);
            close_all();
            return why;
        }
    }
    return NULL;
}

static double as_double(zet_typed_value_t v) {
    switch (v.type) {
    case ZET_VALUE_TYPE_UINT32: return v.value.ui32;
    case ZET_VALUE_TYPE_UINT64: return (double)v.value.ui64;
    case ZET_VALUE_TYPE_FLOAT32: return v.value.fp32;
    case ZET_VALUE_TYPE_FLOAT64: return v.value.fp64;
    case ZET_VALUE_TYPE_BOOL8: return v.value.b8;
    default: return 0;
    }
}

/* Everything the streamer has buffered; the newest report's values into
 * `values` (g->metrics of them). Returns the number of reports, or -1. */
static int read_group(group *g, double *values) {
    size_t size = 0;
    if (zetMetricStreamerReadData(g->streamer, UINT32_MAX, &size, NULL)) return -1;
    if (size == 0) return 0;
    if (size > raw_cap) {
        raw_cap = size;
        raw = realloc(raw, raw_cap);
    }
    if (zetMetricStreamerReadData(g->streamer, UINT32_MAX, &size, raw)) return -1;
    if (size == 0) return 0;

    uint32_t count = 0;
    if (zetMetricGroupCalculateMetricValues(g->group, ZET_METRIC_GROUP_CALCULATION_TYPE_METRIC_VALUES, size, raw,
                                            &count, NULL) ||
        count == 0)
        return 0;
    zet_typed_value_t *vals = calloc(count, sizeof *vals);
    if (zetMetricGroupCalculateMetricValues(g->group, ZET_METRIC_GROUP_CALCULATION_TYPE_METRIC_VALUES, size, raw,
                                            &count, vals)) {
        free(vals);
        return -1;
    }
    uint32_t reports = g->metrics ? count / g->metrics : 0;
    if (reports > 0)
        for (uint32_t m = 0; m < g->metrics; m++) values[m] = as_double(vals[(reports - 1) * g->metrics + m]);
    free(vals);
    return (int)reports;
}

/* ---------------------------------------------------------------- commands */

static void cmd_open(const uint8_t *p, uint32_t n) {
    char names[256];
    if (n >= sizeof names) n = sizeof names - 1;
    memcpy(names, p, n);
    names[n] = 0;
    const char *why = open_groups(names);
    if (why) {
        reply_error("%s", why);
        return;
    }
    out o = ok_reply();
    put_u16(&o, (uint16_t)ngroups);
    for (uint32_t g = 0; g < ngroups; g++) {
        put_str16(&o, groups[g].name);
        put_u16(&o, (uint16_t)groups[g].metrics);
        for (uint32_t m = 0; m < groups[g].metrics; m++) put_str16(&o, groups[g].metric_names[m]);
    }
    send_out(&o);
}

static void cmd_read(void) {
    if (!context) {
        reply_error("not open");
        return;
    }
    out o = ok_reply();
    for (uint32_t g = 0; g < ngroups; g++) {
        double values[64] = {0};
        if (groups[g].metrics > 64) groups[g].metrics = 64;
        int reports = read_group(&groups[g], values);
        if (reports < 0) {
            free(o.data);
            reply_error("zetMetricStreamerReadData %s failed", groups[g].name);
            return;
        }
        put_u32(&o, (uint32_t)reports);
        for (uint32_t m = 0; m < groups[g].metrics; m++) put_f64(&o, values[m]);
    }
    send_out(&o);
}

static int watch(const char *arg) {
    char names[256];
    snprintf(names, sizeof names, "%s", arg);
    const char *why = open_groups(names);
    if (why) {
        fprintf(stderr, "%s\n", why);
        return 1;
    }
    for (;;) {
        sleep(1);
        for (uint32_t g = 0; g < ngroups; g++) {
            double values[64] = {0};
            int reports = read_group(&groups[g], values);
            printf("%s reports %d", groups[g].name, reports);
            for (uint32_t m = 0; m < groups[g].metrics && m < 64; m++)
                printf("  %s %.0f", groups[g].metric_names[m], values[m]);
            printf("\n");
        }
        fflush(stdout);
    }
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--watch") == 0) return watch(argv[2]);
    for (;;) {
        uint8_t head[4];
        if (read_exact(head, 4)) break;
        uint32_t len = (uint32_t)head[0] << 24 | head[1] << 16 | head[2] << 8 | head[3];
        uint8_t *msg = malloc(len ? len : 1);
        if (read_exact(msg, len)) break;
        switch (len ? msg[0] : 0) {
        case 1: cmd_open(msg + 1, len - 1); break;
        case 2: cmd_read(); break;
        case 3:
            close_all();
            reply((uint8_t[]){0}, 1);
            break;
        case 4: {
            out o = ok_reply();
            put(&o, msg + 1, len - 1);
            send_out(&o);
            break;
        }
        default: reply_error("unknown command %d", len ? msg[0] : -1);
        }
        free(msg);
    }
    close_all();
    return 0;
}
