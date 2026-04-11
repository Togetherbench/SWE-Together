I'm using `sd-scripts` (kohya-ss) for SDXL training. When I define multiple resolutions in my dataset TOML config, each image only gets cached at one resolution. I need the SD/SDXL latent caching strategy to support **multi-resolution caching** like the other newer model strategies (Flux, SD3, etc.) already do.

Please modify the codebase to:

1. **Enable multi-resolution caching for SD/SDXL** by updating `library/strategy_sd.py` to match the pattern used in the other strategy files. Look at how `strategy_flux.py` and `strategy_sd3.py` handle `multi_resolution` and apply the same approach.

2. **Add a `skip_duplicate_bucketed_images` config option** so users can avoid duplicate images that map to the same bucket. This should be a boolean field in the dataset config system (both the params dataclass and the schema), wired through the dataset classes, with actual dedup logic that tracks and removes duplicates.

3. **Add an `unwrap_model_for_sampling` utility** in train_util.py that safely unwraps models from the accelerator, handling the case where models have been wrapped by `torch.compile` (they have a `_orig_mod` attribute that needs to be accessed).

4. **Fix `isinstance` checks in `sdxl_original_unet.py`** to handle `torch.compile`'d model layers by checking for `_orig_mod` alongside the isinstance calls.

Make sure existing tests still pass after your changes.
