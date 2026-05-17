Fix the error:
```
  [246/402] Building CXX object lib\Conversion\TritonGPUToLLVM\CMakeFiles\TritonGPUToLLVM.dir\WarpSpecializeUtility.cpp.obj
  FAILED: lib/Conversion/TritonGPUToLLVM/CMakeFiles/TritonGPUToLLVM.dir/WarpSpecializeUtility.cpp.obj 
  <HOST_PATH> <HOST_PATH>  /nologo /TP  -ID:\a\triton-windows\triton-windows\triton-windows\build\cmake.win-amd64-cpython-3.10\lib\Conversion\TritonGPUToLLVM -ID:\a\triton-windows\triton-windows\triton-windows\lib\Conversion\TritonGPUToLLVM -ID:\a\triton-windows\triton-windows\triton-windows\include -ID:\a\triton-windows\triton-windows\triton-windows\. -I<HOST_PATH> -ID:\a\triton-windows\triton-windows\triton-windows\build\cmake.win-amd64-cpython-3.10\include -ID:\a\triton-windows\triton-windows\triton-windows\third_party -ID:\a\triton-windows\triton-windows\triton-windows\build\cmake.win-amd64-cpython-3.10\third_party /DWIN32 /D_WINDOWS /EHsc /nologo /bigobj /Zc:__STDC__ /Zc:preprocessor /permissive- /utf-8 /WX /wd4244 /wd4293 /wd4624 /O2 /Ob2 /DNDEBUG -std:c++17 -MD /showIncludes /Folib\Conversion\TritonGPUToLLVM\CMakeFiles\TritonGPUToLLVM.dir\WarpSpecializeUtility.cpp.obj /Fdlib\Conversion\TritonGPUToLLVM\CMakeFiles\TritonGPUToLLVM.dir\ /FS -c D:\a\triton-windows\triton-windows\triton-windows\lib\Conversion\TritonGPUToLLVM\WarpSpecializeUtility.cpp
  C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.44.35207\include\optional(82): error C2220: the following warning is treated as an error
  C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.44.35207\include\optional(82): warning C4267: 'initializing': conversion from 'size_t' to 'unsigned int', possible loss of data
  C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.44.35207\include\optional(82): note: the template instantiation context (the oldest one first) is
  D:\a\triton-windows\triton-windows\triton-windows\lib\Conversion\TritonGPUToLLVM\WarpSpecializeUtility.cpp(99): note: see reference to function template instantiation 'std::optional<unsigned int>::optional<const _This&,0>(_Ty2) noexcept' being compiled
          with
          [
              _This=size_t,
              _Ty2=const size_t &
          ]
  D:\a\triton-windows\triton-windows\triton-windows\lib\Conversion\TritonGPUToLLVM\WarpSpecializeUtility.cpp(99): note: see the first reference to 'std::optional<unsigned int>::optional' in 'lowerKernelBarriers::<lambda_2>::operator ()'
  C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.44.35207\include\optional(272): note: see reference to function template instantiation 'std::_Optional_construct_base<_Ty>::_Optional_construct_base<const _This&>(std::in_place_t,const _This &)' being compiled
          with
          [
              _Ty=unsigned int,
              _This=size_t
          ]
  D:\a\triton-windows\triton-windows\triton-windows\lib\Conversion\TritonGPUToLLVM\WarpSpecializeUtility.cpp(563): note: see reference to function template instantiation 'std::_Optional_destruct_base<_Ty,true>::_Optional_destruct_base<const _This&>(std::in_place_t,const _This &) noexcept' being compiled
          with
          [
              _Ty=unsigned int,
              _This=size_t
          ]
```
