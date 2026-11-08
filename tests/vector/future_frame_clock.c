/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Test-only interposition: preserve GTK scheduling while exposing a future
 * timestamp through the public frame-time getter used by the viewer. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <gdk/gdk.h>
#include <stdlib.h>

gint64 gdk_frame_clock_get_frame_time(GdkFrameClock *clock)
{
    typedef gint64 (*FrameTimeFunction)(GdkFrameClock *);
    FrameTimeFunction original = (FrameTimeFunction) dlsym(RTLD_NEXT, "gdk_frame_clock_get_frame_time");
    if (original == NULL)
        abort();
    return original(clock) + 8000000;
}
