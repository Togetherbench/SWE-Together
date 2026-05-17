When I run Triton on Windows with AMD GPU, it shows:
```
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:33:26: error: 'tt.load' op operation destroyed but still has uses
        k_scale = tl.load(K_scale_ptr)
                         ^
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:137:51: note: called from
                                4 - STAGE, offs_m, offs_n,
                                                  ^
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:39:53: note: - use: %165 = "tt.splat"(<<UNKNOWN SSA VALUE>>) : (f32) -> tensor<64x64xf32, #ttg.amd_wmma<{version = 2, isTranspose = true, warpsPerCTA = [8, 1]}>>

        qk = tl.dot(q, k).to(tl.float32) * q_scale * k_scale
                                                    ^
LLVM ERROR: operation destroyed but still has uses
#blocked = #ttg.blocked<{sizePerThread = [1], threadsPerWarp = [32], warpsPerCTA = [8], order = [0]}>
#blocked1 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 32], warpsPerCTA = [4, 2], order = [1, 0]}>
#blocked2 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [32, 1], warpsPerCTA = [8, 1], order = [1, 0]}>
#blocked3 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 32], warpsPerCTA = [2, 4], order = [1, 0]}>
#blocked4 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [32, 1], warpsPerCTA = [8, 1], order = [0, 1]}>
#blocked5 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 32], warpsPerCTA = [1, 8], order = [0, 1]}>
#blocked6 = #ttg.blocked<{sizePerThread = [4, 4], threadsPerWarp = [2, 16], warpsPerCTA = [8, 1], order = [1, 0]}>
#blocked7 = #ttg.blocked<{sizePerThread = [4, 4], threadsPerWarp = [1, 32], warpsPerCTA = [8, 1], order = [1, 0]}>
module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 8 : i32, ttg.target = "hip:gfx1200", "ttg.threads-per-warp" = 32 : i32} {
  tt.func public @_attn_fwd(%arg0: !tt.ptr<i8> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg1: !tt.ptr<i8> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg2: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg3: !tt.ptr<f32> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg4: !tt.ptr<f32> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg5: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg6: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg7: !tt.ptr<i1> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg8: !tt.ptr<i32> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg9: i32, %arg10: i32 {tt.divisibility = 16 : i32}, %arg11: i32 {tt.divisibility = 16 : i32}, %arg12: i32 {tt.divisibility = 16 : i32}, %arg13: i32 {tt.divisibility = 16 : i32}, %arg14: i32 {tt.divisibility = 16 : i32}, %arg15: i32 {tt.divisibility = 16 : i32}, %arg16: i32 {tt.divisibility = 16 : i32}, %arg17: i32 {tt.divisibility = 16 : i32}, %arg18: i32 {tt.divisibility = 16 : i32}, %arg19: i32 {tt.divisibility = 16 : i32}, %arg20: i32 {tt.divisibility = 16 : i32}, %arg21: i32 {tt.divisibility = 16 : i32}, %arg22: i32, %arg23: i32, %arg24: i32, %arg25: i32, %arg26: i32, %arg27: i32, %arg28: i32 {tt.divisibility = 16 : i32}, %arg29: i32 {tt.divisibility = 16 : i32}) attributes {noinline = false} {
    %cst = arith.constant dense<1.000000e+00> : tensor<64xf32, #blocked>
    %cst_0 = arith.constant dense<0xFF800000> : tensor<64xf32, #blocked>
    %c0_i32 = arith.constant 0 : i32
    %cst_1 = arith.constant dense<0> : tensor<64x64xi32, #blocked1>
    %cst_2 = arith.constant dense<1.638000e+04> : tensor<64x64xf32, #blocked1>
    %cst_3 = arith.constant dense<0.899999976> : tensor<64x64xf32, #blocked1>
    %cst_4 = arith.constant dense<1560> : tensor<64x1xi32, #blocked2>
    %cst_5 = arith.constant dense<32760> : tensor<64xi32, #blocked>
    %cst_6 = arith.constant dense<-1.000000e+04> : tensor<64x64xf32, #blocked1>
    %cst_7 = arith.constant dense<0.000000e+00> : tensor<64x128xf16, #blocked3>
    %c1_i32 = arith.constant 1 : i32
    %cst_8 = arith.constant dense<0.000000e+00> : tensor<64x64xf32, #blocked1>
    %cst_9 = arith.constant dense<0.000000e+00> : tensor<64x128xf32, #blocked3>
    %c63_i32 = arith.constant 63 : i32
    %c64_i32 = arith.constant 64 : i32
    %c40_i64 = arith.constant 40 : i64
    %0 = tt.get_program_id x : i32
    %1 = tt.get_program_id z : i32
    %2 = arith.extsi %1 : i32 to i64
    %3 = tt.get_program_id y : i32
    %4 = arith.extsi %3 : i32 to i64
    %5 = arith.muli %2, %c40_i64 : i64
    %6 = arith.addi %5, %4 : i64
    %7 = arith.addi %arg28, %c63_i32 : i32
    %8 = arith.divsi %7, %c64_i32 : i32
    %9 = arith.extsi %8 : i32 to i64
    %10 = arith.muli %6, %9 : i64
    %11 = arith.addi %arg29, %c63_i32 : i32
    %12 = arith.divsi %11, %c64_i32 : i32
    %13 = arith.extsi %12 : i32 to i64
    %14 = arith.muli %6, %13 : i64
    %15 = arith.muli %0, %c64_i32 : i32
    %16 = tt.make_range {end = 64 : i32, start = 0 : i32} : tensor<64xi32, #blocked>
    %17 = tt.splat %15 : i32 -> tensor<64xi32, #blocked>
    %18 = arith.addi %17, %16 : tensor<64xi32, #blocked>
    %19 = tt.make_range {end = 128 : i32, start = 0 : i32} : tensor<128xi32, #blocked>
    %20 = arith.extsi %arg10 : i32 to i64
    %21 = arith.muli %2, %20 : i64
    %22 = arith.extsi %arg11 : i32 to i64
    %23 = arith.muli %4, %22 : i64
    %24 = arith.addi %21, %23 : i64
    %25 = tt.addptr %arg0, %24 : !tt.ptr<i8>, i64
    %26 = ttg.convert_layout %18 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %27 = tt.expand_dims %26 {axis = 1 : i32} : tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xi32, #blocked4>
    %28 = ttg.convert_layout %27 : tensor<64x1xi32, #blocked4> -> tensor<64x1xi32, #blocked2>
    %29 = tt.splat %arg12 : i32 -> tensor<64x1xi32, #blocked2>
    %30 = arith.muli %28, %29 : tensor<64x1xi32, #blocked2>
    %31 = tt.splat %25 : !tt.ptr<i8> -> tensor<64x1x!tt.ptr<i8>, #blocked2>
    %32 = tt.addptr %31, %30 : tensor<64x1x!tt.ptr<i8>, #blocked2>, tensor<64x1xi32, #blocked2>
    %33 = ttg.convert_layout %19 : tensor<128xi32, #blocked> -> tensor<128xi32, #ttg.slice<{dim = 0, parent = #blocked5}>>
    %34 = tt.expand_dims %33 {axis = 0 : i32} : tensor<128xi32, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x128xi32, #blocked5>
    %35 = ttg.convert_layout %34 : tensor<1x128xi32, #blocked5> -> tensor<1x128xi32, #blocked3>
    %36 = tt.broadcast %32 : tensor<64x1x!tt.ptr<i8>, #blocked2> -> tensor<64x128x!tt.ptr<i8>, #blocked2>
    %37 = ttg.convert_layout %36 : tensor<64x128x!tt.ptr<i8>, #blocked2> -> tensor<64x128x!tt.ptr<i8>, #blocked3>
    %38 = tt.broadcast %35 : tensor<1x128xi32, #blocked3> -> tensor<64x128xi32, #blocked3>
    %39 = tt.addptr %37, %38 : tensor<64x128x!tt.ptr<i8>, #blocked3>, tensor<64x128xi32, #blocked3>
    %40 = tt.addptr %arg3, %10 : !tt.ptr<f32>, i64
    %41 = tt.addptr %40, %0 : !tt.ptr<f32>, i32
    %42 = arith.extsi %arg13 : i32 to i64
    %43 = arith.muli %2, %42 : i64
    %44 = arith.extsi %arg14 : i32 to i64
    %45 = arith.muli %4, %44 : i64
    %46 = arith.addi %43, %45 : i64
    %47 = tt.addptr %arg1, %46 : !tt.ptr<i8>, i64
    %48 = ttg.convert_layout %16 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>>
    %49 = tt.expand_dims %48 {axis = 0 : i32} : tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x64xi32, #blocked5>
    %50 = ttg.convert_layout %49 : tensor<1x64xi32, #blocked5> -> tensor<1x64xi32, #blocked1>
    %51 = tt.splat %arg15 : i32 -> tensor<1x64xi32, #blocked1>
    %52 = arith.muli %50, %51 : tensor<1x64xi32, #blocked1>
    %53 = tt.splat %47 : !tt.ptr<i8> -> tensor<1x64x!tt.ptr<i8>, #blocked1>
    %54 = tt.addptr %53, %52 : tensor<1x64x!tt.ptr<i8>, #blocked1>, tensor<1x64xi32, #blocked1>
    %55 = ttg.convert_layout %19 : tensor<128xi32, #blocked> -> tensor<128xi32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %56 = tt.expand_dims %55 {axis = 1 : i32} : tensor<128xi32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<128x1xi32, #blocked4>
    %57 = ttg.convert_layout %56 : tensor<128x1xi32, #blocked4> -> tensor<128x1xi32, #blocked2>
    %58 = tt.broadcast %54 : tensor<1x64x!tt.ptr<i8>, #blocked1> -> tensor<128x64x!tt.ptr<i8>, #blocked1>
    %59 = tt.broadcast %57 : tensor<128x1xi32, #blocked2> -> tensor<128x64xi32, #blocked2>
    %60 = ttg.convert_layout %59 : tensor<128x64xi32, #blocked2> -> tensor<128x64xi32, #blocked1>
    %61 = tt.addptr %58, %60 : tensor<128x64x!tt.ptr<i8>, #blocked1>, tensor<128x64xi32, #blocked1>
    %62 = tt.addptr %arg4, %14 : !tt.ptr<f32>, i64
    %63 = arith.extsi %arg16 : i32 to i64
    %64 = arith.muli %2, %63 : i64
    %65 = arith.extsi %arg17 : i32 to i64
    %66 = arith.muli %4, %65 : i64
    %67 = arith.addi %64, %66 : i64
    %68 = tt.addptr %arg2, %67 : !tt.ptr<f16>, i64
    %69 = ttg.convert_layout %16 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %70 = tt.expand_dims %69 {axis = 1 : i32} : tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xi32, #blocked4>
    %71 = ttg.convert_layout %70 : tensor<64x1xi32, #blocked4> -> tensor<64x1xi32, #blocked2>
    %72 = tt.splat %arg18 : i32 -> tensor<64x1xi32, #blocked2>
    %73 = arith.muli %71, %72 : tensor<64x1xi32, #blocked2>
    %74 = tt.splat %68 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked2>
    %75 = tt.addptr %74, %73 : tensor<64x1x!tt.ptr<f16>, #blocked2>, tensor<64x1xi32, #blocked2>
    %76 = tt.broadcast %75 : tensor<64x1x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked2>
    %77 = ttg.convert_layout %76 : tensor<64x128x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked3>
    %78 = tt.addptr %77, %38 : tensor<64x128x!tt.ptr<f16>, #blocked3>, tensor<64x128xi32, #blocked3>
    %79 = arith.extsi %arg19 : i32 to i64
    %80 = arith.muli %2, %79 : i64
    %81 = arith.extsi %arg20 : i32 to i64
    %82 = arith.muli %4, %81 : i64
    %83 = arith.addi %80, %82 : i64
    %84 = tt.addptr %arg5, %83 : !tt.ptr<f16>, i64
    %85 = tt.splat %arg21 : i32 -> tensor<64x1xi32, #blocked2>
    %86 = arith.muli %28, %85 : tensor<64x1xi32, #blocked2>
    %87 = tt.splat %84 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked2>
    %88 = tt.addptr %87, %86 : tensor<64x1x!tt.ptr<f16>, #blocked2>, tensor<64x1xi32, #blocked2>
    %89 = tt.broadcast %88 : tensor<64x1x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked2>
    %90 = ttg.convert_layout %89 : tensor<64x128x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked3>
    %91 = tt.addptr %90, %38 : tensor<64x128x!tt.ptr<f16>, #blocked3>, tensor<64x128xi32, #blocked3>
    %92 = tt.splat %arg28 : i32 -> tensor<64x1xi32, #blocked2>
    %93 = arith.cmpi slt, %28, %92 : tensor<64x1xi32, #blocked2>
    %94 = tt.broadcast %93 : tensor<64x1xi1, #blocked2> -> tensor<64x128xi1, #blocked2>
    %95 = ttg.convert_layout %94 : tensor<64x128xi1, #blocked2> -> tensor<64x128xi1, #blocked3>
    %96 = tt.load %39, %95 : tensor<64x128x!tt.ptr<i8>, #blocked3>
    %97 = tt.load %41 : !tt.ptr<f32>
    %98 = tt.splat %97 : f32 -> tensor<64x64xf32, #blocked1>
    %99 = tt.broadcast %28 : tensor<64x1xi32, #blocked2> -> tensor<64x64xi32, #blocked2>
    %100 = ttg.convert_layout %99 : tensor<64x64xi32, #blocked2> -> tensor<64x64xi32, #blocked1>
    %101 = arith.cmpi sle, %28, %cst_4 : tensor<64x1xi32, #blocked2>
    %102 = tt.broadcast %101 : tensor<64x1xi1, #blocked2> -> tensor<64x64xi1, #blocked2>
    %103 = ttg.convert_layout %102 : tensor<64x64xi1, #blocked2> -> tensor<64x64xi1, #blocked1>
    %104 = arith.muli %arg15, %c64_i32 : i32
    %105 = tt.splat %104 : i32 -> tensor<128x64xi32, #blocked1>
    %106 = arith.muli %arg18, %c64_i32 : i32
    %107 = tt.splat %106 : i32 -> tensor<64x128xi32, #blocked3>
    %108:6 = scf.for %arg30 = %c0_i32 to %arg29 step %c64_i32 iter_args(%arg31 = %cst_9, %arg32 = %cst, %arg33 = %cst_0, %arg34 = %61, %arg35 = %62, %arg36 = %78) -> (tensor<64x128xf32, #blocked3>, tensor<64xf32, #blocked>, tensor<64xf32, #blocked>, tensor<128x64x!tt.ptr<i8>, #blocked1>, !tt.ptr<f32>, tensor<64x128x!tt.ptr<f16>, #blocked3>)  : i32 {
      %116 = arith.subi %arg29, %arg30 : i32
      %117 = tt.splat %116 : i32 -> tensor<1x64xi32, #blocked1>
      %118 = arith.cmpi slt, %50, %117 : tensor<1x64xi32, #blocked1>
      %119 = tt.broadcast %118 : tensor<1x64xi1, #blocked1> -> tensor<128x64xi1, #blocked1>
      %120 = tt.load %arg34, %119 : tensor<128x64x!tt.ptr<i8>, #blocked1>
      %121 = tt.load %arg35 : !tt.ptr<f32>
      %122 = tt.splat %arg30 : i32 -> tensor<64xi32, #blocked>
      %123 = arith.addi %122, %16 : tensor<64xi32, #blocked>
      %124 = ttg.convert_layout %96 : tensor<64x128xi8, #blocked3> -> tensor<64x128xi8, #ttg.dot_op<{opIdx = 0, parent = #blocked6}>>
      %125 = ttg.convert_layout %120 : tensor<128x64xi8, #blocked1> -> tensor<128x64xi8, #ttg.dot_op<{opIdx = 1, parent = #blocked6}>>
      %126 = ttg.convert_layout %cst_1 : tensor<64x64xi32, #blocked1> -> tensor<64x64xi32, #blocked6>
      %127 = tt.dot %124, %125, %126 : tensor<64x128xi8, #ttg.dot_op<{opIdx = 0, parent = #blocked6}>> * tensor<128x64xi8, #ttg.dot_op<{opIdx = 1, parent = #blocked6}>> -> tensor<64x64xi32, #blocked6>
      %128 = ttg.convert_layout %127 : tensor<64x64xi32, #blocked6> -> tensor<64x64xi32, #blocked1>
      %129 = arith.sitofp %128 : tensor<64x64xi32, #blocked1> to tensor<64x64xf32, #blocked1>
      %130 = arith.mulf %129, %98 : tensor<64x64xf32, #blocked1>
      %131 = tt.splat %121 : f32 -> tensor<64x64xf32, #blocked1>
      %132 = arith.mulf %130, %131 : tensor<64x64xf32, #blocked1>
      %133 = ttg.convert_layout %123 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>>
      %134 = tt.expand_dims %133 {axis = 0 : i32} : tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x64xi32, #blocked5>
      %135 = ttg.convert_layout %134 : tensor<1x64xi32, #blocked5> -> tensor<1x64xi32, #blocked1>
      %136 = tt.broadcast %135 : tensor<1x64xi32, #blocked1> -> tensor<64x64xi32, #blocked1>
      %137 = arith.subi %100, %136 : tensor<64x64xi32, #blocked1>
      %138 = math.absi %137 : tensor<64x64xi32, #blocked1>
      %139 = arith.sitofp %138 : tensor<64x64xi32, #blocked1> to tensor<64x64xf32, #blocked1>
      %140 = arith.cmpf ole, %139, %cst_2 : tensor<64x64xf32, #blocked1>
      %141 = arith.cmpf olt, %132, %cst_8 : tensor<64x64xf32, #blocked1>
      %142 = arith.ori %140, %141 : tensor<64x64xi1, #blocked1>
      %143 = arith.mulf %132, %cst_3 : tensor<64x64xf32, #blocked1>
      %144 = arith.select %142, %132, %143 : tensor<64x64xi1, #blocked1>, tensor<64x64xf32, #blocked1>
      %145 = arith.cmpi sgt, %123, %cst_5 : tensor<64xi32, #blocked>
      %146 = ttg.convert_layout %145 : tensor<64xi1, #blocked> -> tensor<64xi1, #ttg.slice<{dim = 0, parent = #blocked5}>>
      %147 = tt.expand_dims %146 {axis = 0 : i32} : tensor<64xi1, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x64xi1, #blocked5>
      %148 = ttg.convert_layout %147 : tensor<1x64xi1, #blocked5> -> tensor<1x64xi1, #blocked1>
      %149 = tt.broadcast %148 : tensor<1x64xi1, #blocked1> -> tensor<64x64xi1, #blocked1>
      %150 = arith.andi %103, %149 : tensor<64x64xi1, #blocked1>
      %151 = arith.select %150, %cst_6, %144 : tensor<64x64xi1, #blocked1>, tensor<64x64xf32, #blocked1>
      %152 = "tt.reduce"(%151) <{axis = 1 : i32}> ({
      ^bb0(%arg37: f32, %arg38: f32):
        %190 = arith.maxnumf %arg37, %arg38 : f32
        tt.reduce.return %190 : f32
      }) : (tensor<64x64xf32, #blocked1>) -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>>
      %153 = ttg.convert_layout %152 : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>> -> tensor<64xf32, #blocked>
      %154 = arith.maxnumf %arg33, %153 : tensor<64xf32, #blocked>
      %155 = ttg.convert_layout %154 : tensor<64xf32, #blocked> -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>>
      %156 = tt.expand_dims %155 {axis = 1 : i32} : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xf32, #blocked4>
      %157 = ttg.convert_layout %156 : tensor<64x1xf32, #blocked4> -> tensor<64x1xf32, #blocked2>
      %158 = tt.broadcast %157 : tensor<64x1xf32, #blocked2> -> tensor<64x64xf32, #blocked2>
      %159 = ttg.convert_layout %158 : tensor<64x64xf32, #blocked2> -> tensor<64x64xf32, #blocked1>
      %160 = arith.subf %151, %159 : tensor<64x64xf32, #blocked1>
      %161 = math.exp2 %160 : tensor<64x64xf32, #blocked1>
      %162 = "tt.reduce"(%161) <{axis = 1 : i32}> ({
      ^bb0(%arg37: f32, %arg38: f32):
        %190 = arith.addf %arg37, %arg38 : f32
        tt.reduce.return %190 : f32
      }) : (tensor<64x64xf32, #blocked1>) -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>>
      %163 = ttg.convert_layout %162 : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>> -> tensor<64xf32, #blocked>
      %164 = arith.subf %arg33, %154 : tensor<64xf32, #blocked>
      %165 = math.exp2 %164 : tensor<64xf32, #blocked>
      %166 = arith.mulf %arg32, %165 : tensor<64xf32, #blocked>
      %167 = arith.addf %166, %163 : tensor<64xf32, #blocked>
      %168 = ttg.convert_layout %165 : tensor<64xf32, #blocked> -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>>
      %169 = tt.expand_dims %168 {axis = 1 : i32} : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xf32, #blocked4>
      %170 = ttg.convert_layout %169 : tensor<64x1xf32, #blocked4> -> tensor<64x1xf32, #blocked2>
      %171 = tt.broadcast %170 : tensor<64x1xf32, #blocked2> -> tensor<64x128xf32, #blocked2>
      %172 = ttg.convert_layout %171 : tensor<64x128xf32, #blocked2> -> tensor<64x128xf32, #blocked3>
      %173 = arith.mulf %arg31, %172 : tensor<64x128xf32, #blocked3>
      %174 = tt.splat %116 : i32 -> tensor<64x1xi32, #blocked2>
      %175 = arith.cmpi slt, %71, %174 : tensor<64x1xi32, #blocked2>
      %176 = tt.broadcast %175 : tensor<64x1xi1, #blocked2> -> tensor<64x128xi1, #blocked2>
      %177 = ttg.convert_layout %176 : tensor<64x128xi1, #blocked2> -> tensor<64x128xi1, #blocked3>
      %178 = tt.load %arg36, %177 : tensor<64x128x!tt.ptr<f16>, #blocked3>
      %179 = arith.truncf %161 : tensor<64x64xf32, #blocked1> to tensor<64x64xf16, #blocked1>
      %180 = ttg.convert_layout %179 : tensor<64x64xf16, #blocked1> -> tensor<64x64xf16, #ttg.dot_op<{opIdx = 0, parent = #blocked7}>>
      %181 = ttg.convert_layout %178 : tensor<64x128xf16, #blocked3> -> tensor<64x128xf16, #ttg.dot_op<{opIdx = 1, parent = #blocked7}>>
      %182 = ttg.convert_layout %cst_7 : tensor<64x128xf16, #blocked3> -> tensor<64x128xf16, #blocked7>
      %183 = tt.dot %180, %181, %182 : tensor<64x64xf16, #ttg.dot_op<{opIdx = 0, parent = #blocked7}>> * tensor<64x128xf16, #ttg.dot_op<{opIdx = 1, parent = #blocked7}>> -> tensor<64x128xf16, #blocked7>
      %184 = ttg.convert_layout %183 : tensor<64x128xf16, #blocked7> -> tensor<64x128xf16, #blocked3>
      %185 = arith.extf %184 : tensor<64x128xf16, #blocked3> to tensor<64x128xf32, #blocked3>
      %186 = arith.addf %173, %185 : tensor<64x128xf32, #blocked3>
      %187 = tt.addptr %arg34, %105 : tensor<128x64x!tt.ptr<i8>, #blocked1>, tensor<128x64xi32, #blocked1>
      %188 = tt.addptr %arg35, %c1_i32 : !tt.ptr<f32>, i32
      %189 = tt.addptr %arg36, %107 : tensor<64x128x!tt.ptr<f16>, #blocked3>, tensor<64x128xi32, #blocked3>
      scf.yield %186, %167, %154, %187, %188, %189 : tensor<64x128xf32, #blocked3>, tensor<64xf32, #blocked>, tensor<64xf32, #blocked>, tensor<128x64x!tt.ptr<i8>, #blocked1>, !tt.ptr<f32>, tensor<64x128x!tt.ptr<f16>, #blocked3>
    }
    %109 = ttg.convert_layout %108#1 : tensor<64xf32, #blocked> -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %110 = tt.expand_dims %109 {axis = 1 : i32} : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xf32, #blocked4>
    %111 = ttg.convert_layout %110 : tensor<64x1xf32, #blocked4> -> tensor<64x1xf32, #blocked2>
    %112 = tt.broadcast %111 : tensor<64x1xf32, #blocked2> -> tensor<64x128xf32, #blocked2>
    %113 = ttg.convert_layout %112 : tensor<64x128xf32, #blocked2> -> tensor<64x128xf32, #blocked3>
    %114 = arith.divf %108#0, %113 : tensor<64x128xf32, #blocked3>
    %115 = arith.truncf %114 : tensor<64x128xf32, #blocked3> to tensor<64x128xf16, #blocked3>
    tt.store %91, %115, %95 : tensor<64x128x!tt.ptr<f16>, #blocked3>
    tt.return
  }
}

{-#
  external_resources: {
    mlir_reproducer: {
      pipeline: "builtin.module(tritongpu-coalesce, tritongpu-F32DotTC{emu-tf32=false}, tritongpu-remove-layout-conversions, tritongpu-optimize-thread-locality, tritonamdgpu-accelerate-matmul{arch-generation-name=gfx1200 kPack=1 matrix-instruction-size=0}, tritongpu-remove-layout-conversions, tritonamdgpu-optimize-epilogue, tritonamdgpu-optimize-dot-operands{arch-generation-name=gfx1200}, tt.func(tritonamdgpu-hoist-layout-conversions), tritongpu-fuse-nested-loops, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, triton-licm, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, tritonamdgpu-schedule-loops{num_stages=4}, tritonamdgpu-pipeline{use_async_copy=false use_pingpong=false}, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, tritongpu-remove-layout-conversions, tritongpu-reduce-data-duplication, tritonamdgpu-reorder-instructions, tt.func(tritonamdgpu-canonicalize-pointers{enable-large-tensor-ptr-canon=false}), canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, tritonamdgpu-convert-buffer-ops{allow-buffer-atomics=true analyze-small-tensor-ofst=false arch-generation-name=gfx1200}, tritonamdgpu-fold-true-cmpi, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, cse, symbol-dce)",
      disable_threading: true,
      verify_each: true
    }
  }
#-}
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:74:0: error: A signal was caught while processing the MLIR module:reproducer generated at `std::errs, please share the reproducer above with Triton project.`; marking pass as failed
#blocked = #ttg.blocked<{sizePerThread = [1], threadsPerWarp = [32], warpsPerCTA = [8], order = [0]}>
#blocked1 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 32], warpsPerCTA = [4, 2], order = [1, 0]}>
#blocked2 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [32, 1], warpsPerCTA = [8, 1], order = [1, 0]}>
#blocked3 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 32], warpsPerCTA = [2, 4], order = [1, 0]}>
#blocked4 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [32, 1], warpsPerCTA = [8, 1], order = [0, 1]}>
#blocked5 = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 32], warpsPerCTA = [1, 8], order = [0, 1]}>
#blocked6 = #ttg.blocked<{sizePerThread = [4, 4], threadsPerWarp = [2, 16], warpsPerCTA = [8, 1], order = [1, 0]}>
#blocked7 = #ttg.blocked<{sizePerThread = [4, 4], threadsPerWarp = [1, 32], warpsPerCTA = [8, 1], order = [1, 0]}>
module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 8 : i32, ttg.target = "hip:gfx1200", "ttg.threads-per-warp" = 32 : i32} {
  tt.func public @_attn_fwd(%arg0: !tt.ptr<i8> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg1: !tt.ptr<i8> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg2: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg3: !tt.ptr<f32> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg4: !tt.ptr<f32> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg5: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg6: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg7: !tt.ptr<i1> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg8: !tt.ptr<i32> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32}, %arg9: i32, %arg10: i32 {tt.divisibility = 16 : i32}, %arg11: i32 {tt.divisibility = 16 : i32}, %arg12: i32 {tt.divisibility = 16 : i32}, %arg13: i32 {tt.divisibility = 16 : i32}, %arg14: i32 {tt.divisibility = 16 : i32}, %arg15: i32 {tt.divisibility = 16 : i32}, %arg16: i32 {tt.divisibility = 16 : i32}, %arg17: i32 {tt.divisibility = 16 : i32}, %arg18: i32 {tt.divisibility = 16 : i32}, %arg19: i32 {tt.divisibility = 16 : i32}, %arg20: i32 {tt.divisibility = 16 : i32}, %arg21: i32 {tt.divisibility = 16 : i32}, %arg22: i32, %arg23: i32, %arg24: i32, %arg25: i32, %arg26: i32, %arg27: i32, %arg28: i32 {tt.divisibility = 16 : i32}, %arg29: i32 {tt.divisibility = 16 : i32}) attributes {noinline = false} {
    %cst = arith.constant dense<1.000000e+00> : tensor<64xf32, #blocked>
    %cst_0 = arith.constant dense<0xFF800000> : tensor<64xf32, #blocked>
    %c0_i32 = arith.constant 0 : i32
    %cst_1 = arith.constant dense<0> : tensor<64x64xi32, #blocked1>
    %cst_2 = arith.constant dense<1.638000e+04> : tensor<64x64xf32, #blocked1>
    %cst_3 = arith.constant dense<0.899999976> : tensor<64x64xf32, #blocked1>
    %cst_4 = arith.constant dense<1560> : tensor<64x1xi32, #blocked2>
    %cst_5 = arith.constant dense<32760> : tensor<64xi32, #blocked>
    %cst_6 = arith.constant dense<-1.000000e+04> : tensor<64x64xf32, #blocked1>
    %cst_7 = arith.constant dense<0.000000e+00> : tensor<64x128xf16, #blocked3>
    %c1_i32 = arith.constant 1 : i32
    %cst_8 = arith.constant dense<0.000000e+00> : tensor<64x64xf32, #blocked1>
    %cst_9 = arith.constant dense<0.000000e+00> : tensor<64x128xf32, #blocked3>
    %c63_i32 = arith.constant 63 : i32
    %c64_i32 = arith.constant 64 : i32
    %c40_i64 = arith.constant 40 : i64
    %0 = tt.get_program_id x : i32
    %1 = tt.get_program_id z : i32
    %2 = arith.extsi %1 : i32 to i64
    %3 = tt.get_program_id y : i32
    %4 = arith.extsi %3 : i32 to i64
    %5 = arith.muli %2, %c40_i64 : i64
    %6 = arith.addi %5, %4 : i64
    %7 = arith.addi %arg28, %c63_i32 : i32
    %8 = arith.divsi %7, %c64_i32 : i32
    %9 = arith.extsi %8 : i32 to i64
    %10 = arith.muli %6, %9 : i64
    %11 = arith.addi %arg29, %c63_i32 : i32
    %12 = arith.divsi %11, %c64_i32 : i32
    %13 = arith.extsi %12 : i32 to i64
    %14 = arith.muli %6, %13 : i64
    %15 = arith.muli %0, %c64_i32 : i32
    %16 = tt.make_range {end = 64 : i32, start = 0 : i32} : tensor<64xi32, #blocked>
    %17 = tt.splat %15 : i32 -> tensor<64xi32, #blocked>
    %18 = arith.addi %17, %16 : tensor<64xi32, #blocked>
    %19 = tt.make_range {end = 128 : i32, start = 0 : i32} : tensor<128xi32, #blocked>
    %20 = arith.extsi %arg10 : i32 to i64
    %21 = arith.muli %2, %20 : i64
    %22 = arith.extsi %arg11 : i32 to i64
    %23 = arith.muli %4, %22 : i64
    %24 = arith.addi %21, %23 : i64
    %25 = tt.addptr %arg0, %24 : !tt.ptr<i8>, i64
    %26 = ttg.convert_layout %18 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %27 = tt.expand_dims %26 {axis = 1 : i32} : tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xi32, #blocked4>
    %28 = ttg.convert_layout %27 : tensor<64x1xi32, #blocked4> -> tensor<64x1xi32, #blocked2>
    %29 = tt.splat %arg12 : i32 -> tensor<64x1xi32, #blocked2>
    %30 = arith.muli %28, %29 : tensor<64x1xi32, #blocked2>
    %31 = tt.splat %25 : !tt.ptr<i8> -> tensor<64x1x!tt.ptr<i8>, #blocked2>
    %32 = tt.addptr %31, %30 : tensor<64x1x!tt.ptr<i8>, #blocked2>, tensor<64x1xi32, #blocked2>
    %33 = ttg.convert_layout %19 : tensor<128xi32, #blocked> -> tensor<128xi32, #ttg.slice<{dim = 0, parent = #blocked5}>>
    %34 = tt.expand_dims %33 {axis = 0 : i32} : tensor<128xi32, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x128xi32, #blocked5>
    %35 = ttg.convert_layout %34 : tensor<1x128xi32, #blocked5> -> tensor<1x128xi32, #blocked3>
    %36 = tt.broadcast %32 : tensor<64x1x!tt.ptr<i8>, #blocked2> -> tensor<64x128x!tt.ptr<i8>, #blocked2>
    %37 = ttg.convert_layout %36 : tensor<64x128x!tt.ptr<i8>, #blocked2> -> tensor<64x128x!tt.ptr<i8>, #blocked3>
    %38 = tt.broadcast %35 : tensor<1x128xi32, #blocked3> -> tensor<64x128xi32, #blocked3>
    %39 = tt.addptr %37, %38 : tensor<64x128x!tt.ptr<i8>, #blocked3>, tensor<64x128xi32, #blocked3>
    %40 = tt.addptr %arg3, %10 : !tt.ptr<f32>, i64
    %41 = tt.addptr %40, %0 : !tt.ptr<f32>, i32
    %42 = arith.extsi %arg13 : i32 to i64
    %43 = arith.muli %2, %42 : i64
    %44 = arith.extsi %arg14 : i32 to i64
    %45 = arith.muli %4, %44 : i64
    %46 = arith.addi %43, %45 : i64
    %47 = tt.addptr %arg1, %46 : !tt.ptr<i8>, i64
    %48 = ttg.convert_layout %16 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>>
    %49 = tt.expand_dims %48 {axis = 0 : i32} : tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x64xi32, #blocked5>
    %50 = ttg.convert_layout %49 : tensor<1x64xi32, #blocked5> -> tensor<1x64xi32, #blocked1>
    %51 = tt.splat %arg15 : i32 -> tensor<1x64xi32, #blocked1>
    %52 = arith.muli %50, %51 : tensor<1x64xi32, #blocked1>
    %53 = tt.splat %47 : !tt.ptr<i8> -> tensor<1x64x!tt.ptr<i8>, #blocked1>
    %54 = tt.addptr %53, %52 : tensor<1x64x!tt.ptr<i8>, #blocked1>, tensor<1x64xi32, #blocked1>
    %55 = ttg.convert_layout %19 : tensor<128xi32, #blocked> -> tensor<128xi32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %56 = tt.expand_dims %55 {axis = 1 : i32} : tensor<128xi32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<128x1xi32, #blocked4>
    %57 = ttg.convert_layout %56 : tensor<128x1xi32, #blocked4> -> tensor<128x1xi32, #blocked2>
    %58 = tt.broadcast %54 : tensor<1x64x!tt.ptr<i8>, #blocked1> -> tensor<128x64x!tt.ptr<i8>, #blocked1>
    %59 = tt.broadcast %57 : tensor<128x1xi32, #blocked2> -> tensor<128x64xi32, #blocked2>
    %60 = ttg.convert_layout %59 : tensor<128x64xi32, #blocked2> -> tensor<128x64xi32, #blocked1>
    %61 = tt.addptr %58, %60 : tensor<128x64x!tt.ptr<i8>, #blocked1>, tensor<128x64xi32, #blocked1>
    %62 = tt.addptr %arg4, %14 : !tt.ptr<f32>, i64
    %63 = arith.extsi %arg16 : i32 to i64
    %64 = arith.muli %2, %63 : i64
    %65 = arith.extsi %arg17 : i32 to i64
    %66 = arith.muli %4, %65 : i64
    %67 = arith.addi %64, %66 : i64
    %68 = tt.addptr %arg2, %67 : !tt.ptr<f16>, i64
    %69 = ttg.convert_layout %16 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %70 = tt.expand_dims %69 {axis = 1 : i32} : tensor<64xi32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xi32, #blocked4>
    %71 = ttg.convert_layout %70 : tensor<64x1xi32, #blocked4> -> tensor<64x1xi32, #blocked2>
    %72 = tt.splat %arg18 : i32 -> tensor<64x1xi32, #blocked2>
    %73 = arith.muli %71, %72 : tensor<64x1xi32, #blocked2>
    %74 = tt.splat %68 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked2>
    %75 = tt.addptr %74, %73 : tensor<64x1x!tt.ptr<f16>, #blocked2>, tensor<64x1xi32, #blocked2>
    %76 = tt.broadcast %75 : tensor<64x1x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked2>
    %77 = ttg.convert_layout %76 : tensor<64x128x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked3>
    %78 = tt.addptr %77, %38 : tensor<64x128x!tt.ptr<f16>, #blocked3>, tensor<64x128xi32, #blocked3>
    %79 = arith.extsi %arg19 : i32 to i64
    %80 = arith.muli %2, %79 : i64
    %81 = arith.extsi %arg20 : i32 to i64
    %82 = arith.muli %4, %81 : i64
    %83 = arith.addi %80, %82 : i64
    %84 = tt.addptr %arg5, %83 : !tt.ptr<f16>, i64
    %85 = tt.splat %arg21 : i32 -> tensor<64x1xi32, #blocked2>
    %86 = arith.muli %28, %85 : tensor<64x1xi32, #blocked2>
    %87 = tt.splat %84 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked2>
    %88 = tt.addptr %87, %86 : tensor<64x1x!tt.ptr<f16>, #blocked2>, tensor<64x1xi32, #blocked2>
    %89 = tt.broadcast %88 : tensor<64x1x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked2>
    %90 = ttg.convert_layout %89 : tensor<64x128x!tt.ptr<f16>, #blocked2> -> tensor<64x128x!tt.ptr<f16>, #blocked3>
    %91 = tt.addptr %90, %38 : tensor<64x128x!tt.ptr<f16>, #blocked3>, tensor<64x128xi32, #blocked3>
    %92 = tt.splat %arg28 : i32 -> tensor<64x1xi32, #blocked2>
    %93 = arith.cmpi slt, %28, %92 : tensor<64x1xi32, #blocked2>
    %94 = tt.broadcast %93 : tensor<64x1xi1, #blocked2> -> tensor<64x128xi1, #blocked2>
    %95 = ttg.convert_layout %94 : tensor<64x128xi1, #blocked2> -> tensor<64x128xi1, #blocked3>
    %96 = tt.load %39, %95 : tensor<64x128x!tt.ptr<i8>, #blocked3>
    %97 = tt.load %41 : !tt.ptr<f32>
    %98 = tt.splat %97 : f32 -> tensor<64x64xf32, #blocked1>
    %99 = tt.broadcast %28 : tensor<64x1xi32, #blocked2> -> tensor<64x64xi32, #blocked2>
    %100 = ttg.convert_layout %99 : tensor<64x64xi32, #blocked2> -> tensor<64x64xi32, #blocked1>
    %101 = arith.cmpi sle, %28, %cst_4 : tensor<64x1xi32, #blocked2>
    %102 = tt.broadcast %101 : tensor<64x1xi1, #blocked2> -> tensor<64x64xi1, #blocked2>
    %103 = ttg.convert_layout %102 : tensor<64x64xi1, #blocked2> -> tensor<64x64xi1, #blocked1>
    %104 = arith.muli %arg15, %c64_i32 : i32
    %105 = tt.splat %104 : i32 -> tensor<128x64xi32, #blocked1>
    %106 = arith.muli %arg18, %c64_i32 : i32
    %107 = tt.splat %106 : i32 -> tensor<64x128xi32, #blocked3>
    %108:6 = scf.for %arg30 = %c0_i32 to %arg29 step %c64_i32 iter_args(%arg31 = %cst_9, %arg32 = %cst, %arg33 = %cst_0, %arg34 = %61, %arg35 = %62, %arg36 = %78) -> (tensor<64x128xf32, #blocked3>, tensor<64xf32, #blocked>, tensor<64xf32, #blocked>, tensor<128x64x!tt.ptr<i8>, #blocked1>, !tt.ptr<f32>, tensor<64x128x!tt.ptr<f16>, #blocked3>)  : i32 {
      %116 = arith.subi %arg29, %arg30 : i32
      %117 = tt.splat %116 : i32 -> tensor<1x64xi32, #blocked1>
      %118 = arith.cmpi slt, %50, %117 : tensor<1x64xi32, #blocked1>
      %119 = tt.broadcast %118 : tensor<1x64xi1, #blocked1> -> tensor<128x64xi1, #blocked1>
      %120 = tt.load %arg34, %119 : tensor<128x64x!tt.ptr<i8>, #blocked1>
      %121 = tt.load %arg35 : !tt.ptr<f32>
      %122 = tt.splat %arg30 : i32 -> tensor<64xi32, #blocked>
      %123 = arith.addi %122, %16 : tensor<64xi32, #blocked>
      %124 = ttg.convert_layout %96 : tensor<64x128xi8, #blocked3> -> tensor<64x128xi8, #ttg.dot_op<{opIdx = 0, parent = #blocked6}>>
      %125 = ttg.convert_layout %120 : tensor<128x64xi8, #blocked1> -> tensor<128x64xi8, #ttg.dot_op<{opIdx = 1, parent = #blocked6}>>
      %126 = ttg.convert_layout %cst_1 : tensor<64x64xi32, #blocked1> -> tensor<64x64xi32, #blocked6>
      %127 = tt.dot %124, %125, %126 : tensor<64x128xi8, #ttg.dot_op<{opIdx = 0, parent = #blocked6}>> * tensor<128x64xi8, #ttg.dot_op<{opIdx = 1, parent = #blocked6}>> -> tensor<64x64xi32, #blocked6>
      %128 = ttg.convert_layout %127 : tensor<64x64xi32, #blocked6> -> tensor<64x64xi32, #blocked1>
      %129 = arith.sitofp %128 : tensor<64x64xi32, #blocked1> to tensor<64x64xf32, #blocked1>
      %130 = arith.mulf %129, %98 : tensor<64x64xf32, #blocked1>
      %131 = tt.splat %121 : f32 -> tensor<64x64xf32, #blocked1>
      %132 = arith.mulf %130, %131 : tensor<64x64xf32, #blocked1>
      %133 = ttg.convert_layout %123 : tensor<64xi32, #blocked> -> tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>>
      %134 = tt.expand_dims %133 {axis = 0 : i32} : tensor<64xi32, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x64xi32, #blocked5>
      %135 = ttg.convert_layout %134 : tensor<1x64xi32, #blocked5> -> tensor<1x64xi32, #blocked1>
      %136 = tt.broadcast %135 : tensor<1x64xi32, #blocked1> -> tensor<64x64xi32, #blocked1>
      %137 = arith.subi %100, %136 : tensor<64x64xi32, #blocked1>
      %138 = math.absi %137 : tensor<64x64xi32, #blocked1>
      %139 = arith.sitofp %138 : tensor<64x64xi32, #blocked1> to tensor<64x64xf32, #blocked1>
      %140 = arith.cmpf ole, %139, %cst_2 : tensor<64x64xf32, #blocked1>
      %141 = arith.cmpf olt, %132, %cst_8 : tensor<64x64xf32, #blocked1>
      %142 = arith.ori %140, %141 : tensor<64x64xi1, #blocked1>
      %143 = arith.mulf %132, %cst_3 : tensor<64x64xf32, #blocked1>
      %144 = arith.select %142, %132, %143 : tensor<64x64xi1, #blocked1>, tensor<64x64xf32, #blocked1>
      %145 = arith.cmpi sgt, %123, %cst_5 : tensor<64xi32, #blocked>
      %146 = ttg.convert_layout %145 : tensor<64xi1, #blocked> -> tensor<64xi1, #ttg.slice<{dim = 0, parent = #blocked5}>>
      %147 = tt.expand_dims %146 {axis = 0 : i32} : tensor<64xi1, #ttg.slice<{dim = 0, parent = #blocked5}>> -> tensor<1x64xi1, #blocked5>
      %148 = ttg.convert_layout %147 : tensor<1x64xi1, #blocked5> -> tensor<1x64xi1, #blocked1>
      %149 = tt.broadcast %148 : tensor<1x64xi1, #blocked1> -> tensor<64x64xi1, #blocked1>
      %150 = arith.andi %103, %149 : tensor<64x64xi1, #blocked1>
      %151 = arith.select %150, %cst_6, %144 : tensor<64x64xi1, #blocked1>, tensor<64x64xf32, #blocked1>
      %152 = "tt.reduce"(%151) <{axis = 1 : i32}> ({
      ^bb0(%arg37: f32, %arg38: f32):
        %190 = arith.maxnumf %arg37, %arg38 : f32
        tt.reduce.return %190 : f32
      }) : (tensor<64x64xf32, #blocked1>) -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>>
      %153 = ttg.convert_layout %152 : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>> -> tensor<64xf32, #blocked>
      %154 = arith.maxnumf %arg33, %153 : tensor<64xf32, #blocked>
      %155 = ttg.convert_layout %154 : tensor<64xf32, #blocked> -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>>
      %156 = tt.expand_dims %155 {axis = 1 : i32} : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xf32, #blocked4>
      %157 = ttg.convert_layout %156 : tensor<64x1xf32, #blocked4> -> tensor<64x1xf32, #blocked2>
      %158 = tt.broadcast %157 : tensor<64x1xf32, #blocked2> -> tensor<64x64xf32, #blocked2>
      %159 = ttg.convert_layout %158 : tensor<64x64xf32, #blocked2> -> tensor<64x64xf32, #blocked1>
      %160 = arith.subf %151, %159 : tensor<64x64xf32, #blocked1>
      %161 = math.exp2 %160 : tensor<64x64xf32, #blocked1>
      %162 = "tt.reduce"(%161) <{axis = 1 : i32}> ({
      ^bb0(%arg37: f32, %arg38: f32):
        %190 = arith.addf %arg37, %arg38 : f32
        tt.reduce.return %190 : f32
      }) : (tensor<64x64xf32, #blocked1>) -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>>
      %163 = ttg.convert_layout %162 : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked1}>> -> tensor<64xf32, #blocked>
      %164 = arith.subf %arg33, %154 : tensor<64xf32, #blocked>
      %165 = math.exp2 %164 : tensor<64xf32, #blocked>
      %166 = arith.mulf %arg32, %165 : tensor<64xf32, #blocked>
      %167 = arith.addf %166, %163 : tensor<64xf32, #blocked>
      %168 = ttg.convert_layout %165 : tensor<64xf32, #blocked> -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>>
      %169 = tt.expand_dims %168 {axis = 1 : i32} : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xf32, #blocked4>
      %170 = ttg.convert_layout %169 : tensor<64x1xf32, #blocked4> -> tensor<64x1xf32, #blocked2>
      %171 = tt.broadcast %170 : tensor<64x1xf32, #blocked2> -> tensor<64x128xf32, #blocked2>
      %172 = ttg.convert_layout %171 : tensor<64x128xf32, #blocked2> -> tensor<64x128xf32, #blocked3>
      %173 = arith.mulf %arg31, %172 : tensor<64x128xf32, #blocked3>
      %174 = tt.splat %116 : i32 -> tensor<64x1xi32, #blocked2>
      %175 = arith.cmpi slt, %71, %174 : tensor<64x1xi32, #blocked2>
      %176 = tt.broadcast %175 : tensor<64x1xi1, #blocked2> -> tensor<64x128xi1, #blocked2>
      %177 = ttg.convert_layout %176 : tensor<64x128xi1, #blocked2> -> tensor<64x128xi1, #blocked3>
      %178 = tt.load %arg36, %177 : tensor<64x128x!tt.ptr<f16>, #blocked3>
      %179 = arith.truncf %161 : tensor<64x64xf32, #blocked1> to tensor<64x64xf16, #blocked1>
      %180 = ttg.convert_layout %179 : tensor<64x64xf16, #blocked1> -> tensor<64x64xf16, #ttg.dot_op<{opIdx = 0, parent = #blocked7}>>
      %181 = ttg.convert_layout %178 : tensor<64x128xf16, #blocked3> -> tensor<64x128xf16, #ttg.dot_op<{opIdx = 1, parent = #blocked7}>>
      %182 = ttg.convert_layout %cst_7 : tensor<64x128xf16, #blocked3> -> tensor<64x128xf16, #blocked7>
      %183 = tt.dot %180, %181, %182 : tensor<64x64xf16, #ttg.dot_op<{opIdx = 0, parent = #blocked7}>> * tensor<64x128xf16, #ttg.dot_op<{opIdx = 1, parent = #blocked7}>> -> tensor<64x128xf16, #blocked7>
      %184 = ttg.convert_layout %183 : tensor<64x128xf16, #blocked7> -> tensor<64x128xf16, #blocked3>
      %185 = arith.extf %184 : tensor<64x128xf16, #blocked3> to tensor<64x128xf32, #blocked3>
      %186 = arith.addf %173, %185 : tensor<64x128xf32, #blocked3>
      %187 = tt.addptr %arg34, %105 : tensor<128x64x!tt.ptr<i8>, #blocked1>, tensor<128x64xi32, #blocked1>
      %188 = tt.addptr %arg35, %c1_i32 : !tt.ptr<f32>, i32
      %189 = tt.addptr %arg36, %107 : tensor<64x128x!tt.ptr<f16>, #blocked3>, tensor<64x128xi32, #blocked3>
      scf.yield %186, %167, %154, %187, %188, %189 : tensor<64x128xf32, #blocked3>, tensor<64xf32, #blocked>, tensor<64xf32, #blocked>, tensor<128x64x!tt.ptr<i8>, #blocked1>, !tt.ptr<f32>, tensor<64x128x!tt.ptr<f16>, #blocked3>
    }
    %109 = ttg.convert_layout %108#1 : tensor<64xf32, #blocked> -> tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>>
    %110 = tt.expand_dims %109 {axis = 1 : i32} : tensor<64xf32, #ttg.slice<{dim = 1, parent = #blocked4}>> -> tensor<64x1xf32, #blocked4>
    %111 = ttg.convert_layout %110 : tensor<64x1xf32, #blocked4> -> tensor<64x1xf32, #blocked2>
    %112 = tt.broadcast %111 : tensor<64x1xf32, #blocked2> -> tensor<64x128xf32, #blocked2>
    %113 = ttg.convert_layout %112 : tensor<64x128xf32, #blocked2> -> tensor<64x128xf32, #blocked3>
    %114 = arith.divf %108#0, %113 : tensor<64x128xf32, #blocked3>
    %115 = arith.truncf %114 : tensor<64x128xf32, #blocked3> to tensor<64x128xf16, #blocked3>
    tt.store %91, %115, %95 : tensor<64x128x!tt.ptr<f16>, #blocked3>
    tt.return
  }
}

{-#
  external_resources: {
    mlir_reproducer: {
      pipeline: "builtin.module(tritongpu-coalesce, tritongpu-F32DotTC{emu-tf32=false}, tritongpu-remove-layout-conversions, tritongpu-optimize-thread-locality, tritonamdgpu-accelerate-matmul{arch-generation-name=gfx1200 kPack=1 matrix-instruction-size=0}, tritongpu-remove-layout-conversions, tritonamdgpu-optimize-epilogue, tritonamdgpu-optimize-dot-operands{arch-generation-name=gfx1200}, tt.func(tritonamdgpu-hoist-layout-conversions), tritongpu-fuse-nested-loops, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, triton-licm, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, tritonamdgpu-schedule-loops{num_stages=4}, tritonamdgpu-pipeline{use_async_copy=false use_pingpong=false}, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, tritongpu-remove-layout-conversions, tritongpu-reduce-data-duplication, tritonamdgpu-reorder-instructions, tt.func(tritonamdgpu-canonicalize-pointers{enable-large-tensor-ptr-canon=false}), canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, tritonamdgpu-convert-buffer-ops{allow-buffer-atomics=true analyze-small-tensor-ofst=false arch-generation-name=gfx1200}, tritonamdgpu-fold-true-cmpi, canonicalize{  max-iterations=10 max-num-rewrites=-1 region-simplify=normal test-convergence=false top-down=true}, cse, symbol-dce)",
      disable_threading: true,
      verify_each: true
    }
  }
#-}
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:74:0: error: Failures have been detected while processing an MLIR pass pipeline
E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:74:0: note: Pipeline failed while executing [`TritonAMDGPUPipeline` on 'builtin.module' operation]: reproducer generated at `std::errs, please share the reproducer above with Triton project.`
Error during model prediction: PassManager::run failed
  0%|                                                                                                                                                                                     | 0/2 [00:21<?, ?it/s]
Error during sampling: PassManager::run failed
!!! Exception during processing !!! PassManager::run failed
Traceback (most recent call last):
  File "E:\ComfyUI\execution.py", line 518, in execute
    output_data, output_ui, has_subgraph, has_pending_tasks = await get_output_data(prompt_id, unique_id, obj, input_data_all, execution_block_cb=execution_block_cb, pre_execute_cb=pre_execute_cb, v3_data=v3_data)
                                                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\execution.py", line 329, in get_output_data
    return_values = await _async_map_node_over_list(prompt_id, unique_id, obj, input_data_all, obj.FUNCTION, allow_interrupt=True, execution_block_cb=execution_block_cb, pre_execute_cb=pre_execute_cb, v3_data=v3_data)
                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\execution.py", line 303, in _async_map_node_over_list
    await process_inputs(input_dict, i)
  File "E:\ComfyUI\execution.py", line 291, in process_inputs
    result = f(**inputs)
             ^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\nodes_sampler.py", line 2588, in process
    raise e
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\nodes_sampler.py", line 2481, in process
    noise_pred, noise_pred_ovi, self.cache_state = predict_with_cfg(
                                                   ^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\nodes_sampler.py", line 1661, in predict_with_cfg
    raise e
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\nodes_sampler.py", line 1508, in predict_with_cfg
    noise_pred_cond, noise_pred_ovi, cache_state_cond = transformer(
                                                        ^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\nn\modules\module.py", line 1779, in _wrapped_call_impl
    return self._call_impl(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\nn\modules\module.py", line 1790, in _call_impl
    return forward_call(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\wanvideo\modules\model.py", line 3240, in forward
    x, x_ip, lynx_ref_feature, x_ovi = block(x, x_ip=x_ip, lynx_ref_feature=lynx_ref_feature, x_ovi=x_ovi, x_onetoall_ref=x_onetoall_ref, onetoall_freqs=onetoall_freqs, attention_mode_override=attention_mode, **kwargs)
                                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\nn\modules\module.py", line 1779, in _wrapped_call_impl
    return self._call_impl(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\nn\modules\module.py", line 1790, in _call_impl
    return forward_call(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\wanvideo\modules\model.py", line 1246, in forward
    y = self.self_attn.forward(q, k, v, seq_lens, lynx_ref_feature=lynx_ref_feature, lynx_ref_scale=lynx_ref_scale,
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\wanvideo\modules\model.py", line 485, in forward
    x = attention(q, k, v, k_lens=seq_lens, attention_mode=attention_mode, heads=self.num_heads, frame_tokens=frame_tokens, transformer_options=transformer_options)
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\wanvideo\modules\attention.py", line 111, in attention
    return sageattn_func_ultravico([q, k, v], multi_factor=transformer_options.get("ultravico_alpha", 0.9), frame_tokens=frame_tokens).contiguous()
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\_ops.py", line 1243, in __call__
    return self._op(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\_library\custom_ops.py", line 347, in backend_impl
    result = self._backend_fns[device_type](*args, **kwargs)
             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\_compile.py", line 54, in inner
    return disable_fn(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\_dynamo\eval_frame.py", line 1227, in _fn
    return fn(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\torch\_library\custom_ops.py", line 382, in wrapped_fn
    return fn(*args, **kwargs)
           ^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\wanvideo\modules\attention.py", line 85, in sageattn_func_ultravico
    return sageattn_ultravico(qkv, attn_mask=attn_mask, dropout_p=dropout_p, is_causal=is_causal, multi_factor=multi_factor, frame_tokens=frame_tokens)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\core.py", line 54, in sage_attention
    o = attn_false(q_int8, k_int8, v, flags, block_bias, decay_mask, q_scale, k_scale,
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py", line 203, in forward
    _attn_fwd[grid](
  File "E:\ComfyUI\venv\Lib\site-packages\triton\runtime\jit.py", line 370, in <lambda>
    return lambda *args, **kwargs: self.run(grid=grid, warmup=False, *args, **kwargs)
                                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\triton\runtime\jit.py", line 720, in run
    kernel = self._do_compile(key, signature, device, constexprs, options, attrs, warmup)
             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\triton\runtime\jit.py", line 849, in _do_compile
    kernel = self.compile(src, target=target, options=options.__dict__)
             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\triton\compiler\compiler.py", line 324, in compile
    next_module = compile_ir(module, metadata)
                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\triton\backends\amd\compiler.py", line 503, in <lambda>
    stages["ttgir"] = lambda src, metadata: self.make_ttgir(src, metadata, options)
                                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "E:\ComfyUI\venv\Lib\site-packages\triton\backends\amd\compiler.py", line 275, in make_ttgir
    pm.run(mod, 'make_ttgir')
RuntimeError: PassManager::run failed
```
What could be the cause?
On this machine, you may read `attn_qk_int8_per_block.py` at @..\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py
--- Content from referenced files ---
Content from @..\ComfyUI\custom_nodes\ComfyUI-WanVideoWrapper\ultravico\sageattn\attn_qk_int8_per_block.py:
# https://github.com/thu-ml/DiT-Extrapolation/blob/ultra-wan/sageattn/attn_qk_int8_per_block.py

import torch
import triton
import triton.language as tl


@triton.jit
def _attn_fwd_inner(acc, l_i, m_i, q, q_scale, kv_len, current_flag,
                    K_ptrs, K_scale_ptr, V_ptrs, stride_kn, stride_vn,
                    Block_bias_ptrs, stride_bbz, stride_bbh, stride_bm, stride_bn,
                    Decay_mask_ptrs, stride_dmz, stride_dmh, stride_dm, stride_dn,
                    start_m,
                    BLOCK_M: tl.constexpr, HEAD_DIM: tl.constexpr, BLOCK_N: tl.constexpr,
                    STAGE: tl.constexpr, offs_m: tl.constexpr, offs_n: tl.constexpr,
                    xpos_xi: tl.constexpr = 0.9999934149894527,
                    frame_tokens: tl.constexpr = 1560,
                    sigmoid_a: tl.constexpr = 1.0,
                    alpha_xpos_xi: tl.constexpr = 0.9999967941742395,
                    beta_xpos_xi: tl.constexpr = 0.9999860536252945,
                    sink_width: tl.constexpr = 4,
                    window_width: tl.constexpr = 16,
                    multi_factor: tl.constexpr = None,
                    entropy_factor: tl.constexpr = None,
                    ):


    lo, hi = 0, kv_len
    for start_n in range(lo, hi, BLOCK_N):
        start_n = tl.multiple_of(start_n, BLOCK_N)
        k_mask = offs_n[None, :] < (kv_len - start_n)
        k = tl.load(K_ptrs, mask = k_mask)
        k_scale = tl.load(K_scale_ptr)


        m = offs_m[:, None]
        n = start_n + offs_n

        qk = tl.dot(q, k).to(tl.float32) * q_scale * k_scale

        window_th   =  frame_tokens * window_width / 2
        dist2       = tl.abs(m - n).to(tl.int32)
        dist_mask   = dist2 <= window_th

        negative_mask = (qk<0)

        qk = tl.where(dist_mask | negative_mask, qk, qk*multi_factor)

        window3 = (m <= frame_tokens) & (n > window_width*frame_tokens)
        qk = tl.where(window3, -1e4, qk)


        m_ij = tl.maximum(m_i, tl.max(qk, 1))
        qk = qk - m_ij[:, None]
        p = tl.math.exp2(qk)
        l_ij = tl.sum(p, 1)

        alpha = tl.math.exp2(m_i - m_ij)
        l_i = l_i * alpha + l_ij

        acc = acc * alpha[:, None]

        v = tl.load(V_ptrs, mask = offs_n[:, None] < (kv_len - start_n))
        p = p.to(tl.float16)

        acc += tl.dot(p, v, out_dtype=tl.float16)
        m_i = m_ij
        K_ptrs += BLOCK_N * stride_kn
        K_scale_ptr += 1
        V_ptrs += BLOCK_N * stride_vn
    return acc, l_i

@triton.jit
def _attn_fwd(Q, K, V, Q_scale, K_scale, Out,
              Block_bias, Decay_mask,
              flags, stride_f_b, stride_f_h,
              stride_qz, stride_qh, stride_qn,
              stride_kz, stride_kh, stride_kn,
              stride_vz, stride_vh, stride_vn,
              stride_oz, stride_oh, stride_on,
              stride_bbz, stride_bbh, stride_bm, stride_bn,
              stride_dmz, stride_dmh, stride_dm, stride_dn,
              qo_len, kv_len, H: tl.constexpr, num_kv_groups: tl.constexpr,
              HEAD_DIM: tl.constexpr,
              BLOCK_M: tl.constexpr,
              BLOCK_N: tl.constexpr,
              STAGE: tl.constexpr,
              xpos_xi: tl.constexpr = 0.9999934149894527,
              frame_tokens: tl.constexpr = 1560,
              sigmoid_a: tl.constexpr = 1.0,
              alpha_xpos_xi: tl.constexpr = 0.9999967941742395,
              beta_xpos_xi: tl.constexpr = 0.9999860536252945,
              sink_width: tl.constexpr = 4,
              window_width: tl.constexpr = 16,
              multi_factor: tl.constexpr = None,
              entropy_factor: tl.constexpr = None,
              ):
    start_m = tl.program_id(0)

    off_z = tl.program_id(2).to(tl.int64)
    off_h = tl.program_id(1).to(tl.int64)

    q_scale_offset = (off_z * H + off_h) * tl.cdiv(qo_len, BLOCK_M)
    k_scale_offset = (off_z * (H // num_kv_groups) + off_h // num_kv_groups) * tl.cdiv(kv_len, BLOCK_N)

    flag_ptr = flags + off_z * stride_f_b + off_h * stride_f_h
    current_flag = tl.load(flag_ptr)

    offs_m = start_m * BLOCK_M + tl.arange(0, BLOCK_M)
    offs_n = tl.arange(0, BLOCK_N)
    offs_k = tl.arange(0, HEAD_DIM)
    Q_ptrs = Q + (off_z * stride_qz + off_h * stride_qh) + offs_m[:, None] * stride_qn + offs_k[None, :]
    Q_scale_ptr = Q_scale + q_scale_offset + start_m
    K_ptrs = K + (off_z * stride_kz + (off_h // num_kv_groups) * stride_kh) + offs_n[None, :] * stride_kn + offs_k[:, None]
    K_scale_ptr = K_scale + k_scale_offset
    V_ptrs = V + (off_z * stride_vz + (off_h // num_kv_groups) * stride_vh) + offs_n[:, None] * stride_vn + offs_k[None, :]
    O_block_ptr = Out + (off_z * stride_oz + off_h * stride_oh) + offs_m[:, None] * stride_on + offs_k[None, :]

    # # 计算block_bias指针
    Block_bias_ptrs = Block_bias + off_z * stride_bbz + off_h * stride_bbh

    # 计算decay_mask指针
    Decay_mask_ptrs = Decay_mask + off_z * stride_dmz + off_h * stride_dmh

    m_i = tl.zeros([BLOCK_M], dtype=tl.float32) - float("inf")
    l_i = tl.zeros([BLOCK_M], dtype=tl.float32) + 1.0
    acc = tl.zeros([BLOCK_M, HEAD_DIM], dtype=tl.float32)

    q = tl.load(Q_ptrs, mask = offs_m[:, None] < qo_len)
    q_scale = tl.load(Q_scale_ptr)
    acc, l_i = _attn_fwd_inner(acc, l_i, m_i, q, q_scale, kv_len, current_flag, K_ptrs, K_scale_ptr, V_ptrs,
                                stride_kn, stride_vn,
                                Block_bias_ptrs, stride_bbz, stride_bbh, stride_bm, stride_bn,
                                Decay_mask_ptrs, stride_dmz, stride_dmh, stride_dm, stride_dn,
                                start_m,
                                BLOCK_M, HEAD_DIM, BLOCK_N,
                                4 - STAGE, offs_m, offs_n,
                                xpos_xi=xpos_xi,
                                frame_tokens=frame_tokens,
                                sigmoid_a=sigmoid_a,
                                alpha_xpos_xi=alpha_xpos_xi,
                                beta_xpos_xi=beta_xpos_xi,
                                sink_width=sink_width,
                                window_width=window_width,
                                multi_factor=multi_factor,
                                entropy_factor=entropy_factor,
                                )
    acc = acc / l_i[:, None]
    tl.store(O_block_ptr, acc.to(Out.type.element_ty), mask = (offs_m[:, None] < qo_len))

def forward(q, k, v, flags, block_bias, decay_mask, q_scale, k_scale, tensor_layout="HND", output_dtype=torch.float16,
              xpos_xi: tl.constexpr = 0.9999934149894527,
              frame_tokens: tl.constexpr = 1560,
              sigmoid_a: tl.constexpr = 1.0,
              alpha_xpos_xi: tl.constexpr = 0.9999967941742395,
              beta_xpos_xi: tl.constexpr = 0.9999860536252945,
              BLOCK_M: tl.constexpr = 128,
              BLOCK_N: tl.constexpr = 128,
              sink_width: tl.constexpr = 4,
              window_width: tl.constexpr = 16,
              multi_factor: tl.constexpr = None,
              entropy_factor: tl.constexpr = None,
              ):
    stage = 1

    o = torch.empty(q.shape, dtype=output_dtype, device=q.device)

    b, h_qo, qo_len, head_dim = q.shape
    if block_bias is None:
        block_bias = torch.zeros((b, h_qo, (qo_len + BLOCK_M - 1) // BLOCK_M, (qo_len + BLOCK_N - 1) // BLOCK_N), dtype=torch.float16, device=q.device)

    if decay_mask is None:
        decay_mask = torch.zeros((b, h_qo, (qo_len + BLOCK_M - 1) // BLOCK_M, (qo_len + BLOCK_N - 1) // BLOCK_N), dtype=torch.bool, device=q.device)

    if tensor_layout == "HND":
        b, h_qo, qo_len, head_dim = q.shape
        _, h_kv, kv_len, _ = k.shape

        stride_bz_q, stride_h_q, stride_seq_q = q.stride(0), q.stride(1), q.stride(2)
        stride_bz_k, stride_h_k, stride_seq_k = k.stride(0), k.stride(1), k.stride(2)
        stride_bz_v, stride_h_v, stride_seq_v = v.stride(0), v.stride(1), v.stride(2)
        stride_bz_o, stride_h_o, stride_seq_o = o.stride(0), o.stride(1), o.stride(2)
        stride_bbz, stride_bbh, stride_bm, stride_bn = block_bias.stride()
        stride_dmz, stride_dmh, stride_dm, stride_dn = decay_mask.stride()
    # elif tensor_layout == "NHD":
    #     b, qo_len, h_qo, head_dim = q.shape
    #     _, kv_len, h_kv, _ = k.shape

    #     stride_bz_q, stride_h_q, stride_seq_q = q.stride(0), q.stride(2), q.stride(1)
    #     stride_bz_k, stride_h_k, stride_seq_k = k.stride(0), k.stride(2), k.stride(1)
    #     stride_bz_v, stride_h_v, stride_seq_v = v.stride(0), v.stride(2), v.stride(1)
    #     stride_bz_o, stride_h_o, stride_seq_o = o.stride(0), o.stride(2), o.stride(1)
    #     stride_bbz, stride_bbh, stride_bm, stride_bn = block_bias.stride(0), block_bias.stride(2), block_bias.stride(1), block_bias.stride(3)
    else:
        raise ValueError(f"tensor_layout {tensor_layout} not supported")

    stride_f_b, stride_f_h = flags.stride()

    HEAD_DIM_K = head_dim
    num_kv_groups = h_qo // h_kv

    grid = (triton.cdiv(qo_len, BLOCK_M), h_qo, b)
    _attn_fwd[grid](
        q, k, v, q_scale, k_scale, o,
        block_bias, decay_mask,
        flags,
        stride_f_b, stride_f_h,
        stride_bz_q, stride_h_q, stride_seq_q,
        stride_bz_k, stride_h_k, stride_seq_k,
        stride_bz_v, stride_h_v, stride_seq_v,
        stride_bz_o, stride_h_o, stride_seq_o,
        stride_bbz, stride_bbh, stride_bm, stride_bn,
        stride_dmz, stride_dmh, stride_dm, stride_dn,
        qo_len, kv_len,
        h_qo, num_kv_groups,
        BLOCK_M=BLOCK_M, BLOCK_N=BLOCK_N, HEAD_DIM=HEAD_DIM_K,
        STAGE=stage,
        num_warps=4 if head_dim == 64 else 8,
        num_stages=3 if head_dim == 64 else 4,
        xpos_xi=xpos_xi,
        frame_tokens=frame_tokens,
        sigmoid_a=sigmoid_a,
        alpha_xpos_xi=alpha_xpos_xi,
        beta_xpos_xi=beta_xpos_xi,
        sink_width=sink_width,
        window_width=window_width,
        multi_factor=multi_factor,
        entropy_factor=entropy_factor,
        )
    return o
--- End of content ---
