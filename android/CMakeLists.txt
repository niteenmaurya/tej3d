cmake_minimum_required(VERSION 3.16)
project(tej3d_android LANGUAGES CXX)

set(TEJ3D_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../native" "${CMAKE_CURRENT_BINARY_DIR}/tej3d_native")
