#include "ORTBridge.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>

struct MusicORT {
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
};

static bool success(const OrtApi *api, OrtStatus *status, char *error, size_t length) {
    if (!status) return true;
    snprintf(error, length, "%s", api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return false;
}

void music_ort_close(MusicORT *runtime) {
    if (!runtime) return;
    const OrtApi *api = runtime->api;
    if (runtime->memory) api->ReleaseMemoryInfo(runtime->memory);
    if (runtime->session) api->ReleaseSession(runtime->session);
    if (runtime->env) api->ReleaseEnv(runtime->env);
    free(runtime);
}

MusicORT *music_ort_open(const char *path, int threads, char *error, size_t length) {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) {
        snprintf(error, length, "ONNX Runtime API unavailable");
        return NULL;
    }
    MusicORT *runtime = calloc(1, sizeof(*runtime));
    if (!runtime) {
        snprintf(error, length, "ONNX Runtime allocation failed");
        return NULL;
    }
    runtime->api = api;
    OrtSessionOptions *options = NULL;
    bool opened =
        success(api, api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "Music", &runtime->env), error, length) &&
        success(api, api->CreateSessionOptions(&options), error, length) &&
        success(api, api->SetIntraOpNumThreads(options, threads), error, length) &&
        success(api, api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_EXTENDED), error, length) &&
        success(api, api->CreateSession(runtime->env, path, options, &runtime->session), error, length) &&
        success(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &runtime->memory), error, length);
    if (options) api->ReleaseSessionOptions(options);
    if (opened) return runtime;
    music_ort_close(runtime);
    return NULL;
}

bool music_ort_run(MusicORT *runtime, float *spec, float *mask, char *error, size_t length) {
    const OrtApi *api = runtime->api;
    const int64_t shape[] = {1, 4, 1025, 801};
    const size_t bytes = 4 * 1025 * 801 * sizeof(float);
    const char *input_names[] = {"spec"};
    const char *output_names[] = {"mask"};
    OrtValue *input = NULL;
    OrtValue *output = NULL;
    bool created =
        success(api, api->CreateTensorWithDataAsOrtValue(runtime->memory, spec, bytes, shape, 4,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input), error, length) &&
        success(api, api->CreateTensorWithDataAsOrtValue(runtime->memory, mask, bytes, shape, 4,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &output), error, length);
    bool ran = false;
    if (created) {
        const OrtValue *inputs[] = {input};
        ran = success(api, api->Run(runtime->session, NULL, input_names, inputs, 1,
                                    output_names, 1, &output), error, length);
    }
    if (output) api->ReleaseValue(output);
    if (input) api->ReleaseValue(input);
    return ran;
}
