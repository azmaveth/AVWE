cmake_minimum_required(VERSION 3.13)

# General compilation options
if (MSVC)
	string(REGEX REPLACE "/W[0-4]" "/W4" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
	add_compile_options(/permissive-)
else()
	add_compile_options(-Wall -Wextra)
endif()

set(CMAKE_CXX_STANDARD          17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS        OFF)

project(avwe CXX)
add_executable(avwe src/main.cpp)
target_compile_features(avwe PUBLIC cxx_std_17)
