#ifndef MUSIC_ORT_BRIDGE_H
#define MUSIC_ORT_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

typedef struct MusicORT MusicORT;

MusicORT *music_ort_open(const char *path, int threads, char *error, size_t error_length);
bool music_ort_run(MusicORT *session, float *spec, float *mask, char *error, size_t error_length);
void music_ort_close(MusicORT *session);

#endif
