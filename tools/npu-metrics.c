/* List the Level Zero metric groups (hardware counters) each device offers.
 *
 *   L=$(nix build nixpkgs#level-zero --no-link --print-out-paths)
 *   gcc -I$L/include npu-metrics.c -L$L/lib -lze_loader -Wl,-rpath,$L/lib -o npu-metrics
 *   ZET_ENABLE_METRICS=1 LD_LIBRARY_PATH=/run/opengl-driver/lib ./npu-metrics
 */
#include <stdio.h>
#include <stdlib.h>
#include <level_zero/ze_api.h>
#include <level_zero/zet_api.h>

#define CHECK(x) do { ze_result_t r = (x); if (r) { printf("%s failed: 0x%x\n", #x, r); return 1; } } while (0)

int main(void) {
    CHECK(zeInit(0));
    uint32_t nd = 0;
    CHECK(zeDriverGet(&nd, NULL));
    ze_driver_handle_t *drivers = calloc(nd, sizeof *drivers);
    CHECK(zeDriverGet(&nd, drivers));
    for (uint32_t d = 0; d < nd; d++) {
        uint32_t ndev = 0;
        CHECK(zeDeviceGet(drivers[d], &ndev, NULL));
        ze_device_handle_t *devs = calloc(ndev, sizeof *devs);
        CHECK(zeDeviceGet(drivers[d], &ndev, devs));
        for (uint32_t i = 0; i < ndev; i++) {
            ze_device_properties_t p = {.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES};
            zeDeviceGetProperties(devs[i], &p);
            printf("device: %s (type %d)\n", p.name, p.type);
            uint32_t ng = 0;
            ze_result_t r = zetMetricGroupGet(devs[i], &ng, NULL);
            if (r) { printf("  zetMetricGroupGet: 0x%x\n", r); continue; }
            printf("  %u metric groups\n", ng);
            zet_metric_group_handle_t *groups = calloc(ng, sizeof *groups);
            zetMetricGroupGet(devs[i], &ng, groups);
            for (uint32_t g = 0; g < ng; g++) {
                zet_metric_group_properties_t gp = {.stype = ZET_STRUCTURE_TYPE_METRIC_GROUP_PROPERTIES};
                zetMetricGroupGetProperties(groups[g], &gp);
                printf("  group %-24s sampling 0x%x  %u metrics  %s\n", gp.name, gp.samplingType, gp.metricCount, gp.description);
                uint32_t nm = gp.metricCount;
                zet_metric_handle_t *ms = calloc(nm, sizeof *ms);
                zetMetricGet(groups[g], &nm, ms);
                for (uint32_t m = 0; m < nm; m++) {
                    zet_metric_properties_t mp = {.stype = ZET_STRUCTURE_TYPE_METRIC_PROPERTIES};
                    zetMetricGetProperties(ms[m], &mp);
                    printf("      %-28s %-10s %s\n", mp.name, mp.resultUnits, mp.description);
                }
            }
        }
    }
    return 0;
}
