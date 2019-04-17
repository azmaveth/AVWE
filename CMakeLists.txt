cmake_minimum_required(VERSION 3.13)
project(avwe CXX)
add_executable(avwe src/main.cpp)
target_compile_features(avwe PUBLIC cxx_std_17)
