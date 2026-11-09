find_package(PkgConfig REQUIRED)
pkg_check_modules(VECTOR_PROBE REQUIRED IMPORTED_TARGET json-glib-1.0 gee-0.8 cairo)

# Compile the same renderer as pdfpc; no separate rendering implementation.
vala_precompile(VECTOR_PROBE_C
    src/classes/vector_scene.vala
    tests/vector/vector_probe.vala
DIRECTORY
    ${CMAKE_BINARY_DIR}/tests/vector/generated
PACKAGES
    json-glib-1.0
    gee-0.8
    cairo
)
add_executable(vector-probe ${VECTOR_PROBE_C})
target_link_libraries(vector-probe PkgConfig::VECTOR_PROBE m)
include(CheckCCompilerFlag)
check_c_compiler_flag(-Wincompatible-pointer-types VECTOR_PROBE_POINTER_FLAG)
if(VECTOR_PROBE_POINTER_FLAG)
    target_compile_options(vector-probe PRIVATE -Wno-incompatible-pointer-types)
endif()

# Keep writer checks independent of GTK, a display and the Python image packages.
pkg_check_modules(VECTOR_TRACE_PROBE REQUIRED IMPORTED_TARGET glib-2.0 gobject-2.0)
vala_precompile(VECTOR_TRACE_WRITER_C
    src/classes/vector_trace_writer.vala
    tests/vector/trace_writer_probe.vala
DIRECTORY
    ${CMAKE_BINARY_DIR}/tests/vector/trace-generated
)
add_executable(vector-trace-writer-probe ${VECTOR_TRACE_WRITER_C})
target_link_libraries(vector-trace-writer-probe PkgConfig::VECTOR_TRACE_PROBE m)
if(VECTOR_PROBE_POINTER_FLAG)
    target_compile_options(vector-trace-writer-probe PRIVATE -Wno-incompatible-pointer-types)
endif()

find_package(PythonInterp 3 QUIET)
if(PYTHONINTERP_FOUND)
    add_test(NAME vector-trace-writer
        COMMAND ${PYTHON_EXECUTABLE} -B ${CMAKE_SOURCE_DIR}/tests/vector/test_trace_writer.py
            $<TARGET_FILE:vector-trace-writer-probe>)
    execute_process(COMMAND ${PYTHON_EXECUTABLE} -c "import PIL, pypdf, reportlab"
        RESULT_VARIABLE VECTOR_PYTHON_DEPS OUTPUT_QUIET ERROR_QUIET)
    if(VECTOR_PYTHON_DEPS EQUAL 0)
        add_test(NAME vector-renderer
            COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/vector/test_renderer.py
                $<TARGET_FILE:vector-probe> --output ${CMAKE_BINARY_DIR}/tests/vector/renderer)
        find_program(VECTOR_XVFB Xvfb)
        find_program(VECTOR_XDOTOOL xdotool)
        find_program(VECTOR_DBUS_RUN dbus-run-session)
        find_program(VECTOR_IMAGE_IMPORT import)
        if(VECTOR_XVFB AND VECTOR_XDOTOOL AND VECTOR_DBUS_RUN AND VECTOR_IMAGE_IMPORT)
            add_test(NAME vector-gui
                COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/vector/test_gui.py
                    $<TARGET_FILE:pdfpc> --output ${CMAKE_BINARY_DIR}/tests/vector/gui)
            set_tests_properties(vector-gui PROPERTIES TIMEOUT 90)
            if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
                pkg_check_modules(VECTOR_GDK REQUIRED IMPORTED_TARGET gdk-3.0)
                add_library(vector-future-frame-clock SHARED tests/vector/future_frame_clock.c)
                target_link_libraries(vector-future-frame-clock PRIVATE PkgConfig::VECTOR_GDK ${CMAKE_DL_LIBS})
                add_test(NAME vector-gui-future-clock
                    COMMAND ${PYTHON_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tests/vector/test_gui.py
                        $<TARGET_FILE:pdfpc> --output ${CMAKE_BINARY_DIR}/tests/vector/gui-future-clock
                        --future-frame-clock $<TARGET_FILE:vector-future-frame-clock>)
                set_tests_properties(vector-gui-future-clock PROPERTIES TIMEOUT 90)
            endif()
        endif()
    else()
        message(STATUS "Vector tests need Python Pillow, pypdf and reportlab")
    endif()
endif()
