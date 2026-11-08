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

find_package(PythonInterp 3 QUIET)
if(PYTHONINTERP_FOUND)
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
        endif()
    else()
        message(STATUS "Vector tests need Python Pillow, pypdf and reportlab")
    endif()
endif()
