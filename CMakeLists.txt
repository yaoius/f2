cmake_minimum_required(VERSION 3.10)
project(f2)

set(CMAKE_CXX_STANDARD 14)

add_subdirectory(deps)
add_subdirectory(src)

file(COPY shaders DESTINATION ${CMAKE_BINARY_DIR})
file(COPY kernels DESTINATION ${CMAKE_BINARY_DIR})