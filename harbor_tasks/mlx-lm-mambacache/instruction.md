The `batch_generate` function in `mlx_lm` doesn't work with prompt caches for hybrid models that use `MambaCache` (like Qwen3-Next, Falcon-H1, and other models with linear attention or SSM layers). When you try to pass `prompt_caches` to `batch_generate` with these models, it fails with:

```
ValueError: <class 'mlx_lm.models.cache.MambaCache'> does not yet support batching with history
```

The root cause is in `_merge_caches()` in `generate.py` -- it only handles `KVCache` and `RotatingKVCache`, but hybrid models also use `ArraysCache`/`MambaCache` (for SSM layers) and `CacheList` (which wraps mixed cache types per layer).

Add batching support for `ArraysCache` (parent of `MambaCache`) and `CacheList` so that `batch_generate` works with prompt caches for these hybrid models. Specifically:

1. **`ArraysCache`** needs: `merge(cls, caches)` classmethod, `extract(self, idx)`, `prepare(self, *, left_padding=None, lengths=None, right_padding=None)`, and `finalize(self)` methods. Also add `_lengths` attribute support for right padding mask generation in `make_mask()`.

2. **`CacheList`** needs: `merge(cls, cache_lists)` classmethod and `extract(self, idx)` method that recursively merge/extract sub-caches.

3. **`_merge_caches()`** in `generate.py` needs to handle `ArraysCache` and `CacheList` types in addition to `KVCache` and `RotatingKVCache`.

4. Write comprehensive unit tests in `tests/test_mamba_cache_batching.py`.
