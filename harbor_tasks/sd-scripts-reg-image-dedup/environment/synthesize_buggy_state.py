"""
Apply the min_orig_resolution feature to sd-scripts library/train_util.py,
library/config_util.py, and train_network.py.

This creates the "starting state" for the benchmark task:
- Feature is fully added (min/max_orig_resolution filtering, rebalance logic)
- BUT the regularization balancing loop is DUPLICATED (not yet refactored)
- update_dataset_image_counts() is called twice in the DreamBooth filter override
- Agent must refactor by extracting a shared helper and adding update_counts param
"""
import re

# ── config_util.py ───────────────────────────────────────────────────────────

with open("library/config_util.py", "r", encoding="utf-8") as f:
    src = f.read()

# 1. Add min/max_orig_resolution to BaseDatasetParams
src = src.replace(
    "    resize_interpolation: Optional[str] = None\n",
    "    resize_interpolation: Optional[str] = None\n"
    "    min_orig_resolution: float = 0.0\n"
    "    max_orig_resolution: float = float(\"inf\")\n",
    1,
)

# 2. Add to ConfigSanitizer.DATASET_ASCENDABLE_SCHEMA
src = src.replace(
    '        "resize_interpolation": str,\n',
    '        "resize_interpolation": str,\n'
    '        "min_orig_resolution": float,\n'
    '        "max_orig_resolution": float,\n',
    1,
)

# 3. Add to ARGPARSE_NULLABLE_OPTNAMES
src = src.replace(
    '        "resolution",\n',
    '        "resolution",\n'
    '        "min_orig_resolution",\n'
    '        "max_orig_resolution",\n',
    1,
)

# 4. Add to print_info output in generate_dataset_group_by_blueprint
src = src.replace(
    '                  resolution: {(dataset.width, dataset.height)}\n',
    '                  resolution: {(dataset.width, dataset.height)}\n'
    '                  min_orig_resolution: {dataset.min_orig_resolution}\n'
    '                  max_orig_resolution: {dataset.max_orig_resolution}\n',
    1,
)

with open("library/config_util.py", "w", encoding="utf-8") as f:
    f.write(src)

print("config_util.py patched")

# ── train_util.py ─────────────────────────────────────────────────────────────

with open("library/train_util.py", "r", encoding="utf-8") as f:
    src = f.read()

# 1. Add min/max_orig_resolution to BaseDataset.__init__ signature
src = src.replace(
    "        resize_interpolation: Optional[str] = None,\n"
    "    ) -> None:\n"
    "        super().__init__()\n",
    "        resize_interpolation: Optional[str] = None,\n"
    "        min_orig_resolution: float = 0.0,\n"
    "        max_orig_resolution: float = float(\"inf\"),\n"
    "    ) -> None:\n"
    "        super().__init__()\n",
    1,
)

# 2. Store the new attributes in BaseDataset.__init__ (after resize_interpolation storage)
src = src.replace(
    "        self.resize_interpolation = resize_interpolation\n"
    "\n"
    "        self.image_data: Dict[str, ImageInfo] = {}\n",
    "        self.resize_interpolation = resize_interpolation\n"
    "\n"
    "        assert (\n"
    "            min_orig_resolution <= max_orig_resolution\n"
    "        ), f\"min_orig_resolution {min_orig_resolution} cannot be larger than to max_orig_resolution {max_orig_resolution}\"\n"
    "        self.min_orig_resolution = min_orig_resolution\n"
    "        self.max_orig_resolution = max_orig_resolution\n"
    "\n"
    "        self.image_data: Dict[str, ImageInfo] = {}\n",
    1,
)

# 3. Add new helper methods after set_seed (after the adjust_min_max method block)
NEW_BASEDATASET_METHODS = '''
    def check_orig_resolution(self, image_size: Tuple[int, int]) -> bool:
        orig_resolution = math.sqrt(image_size[0] * image_size[1])
        # min_orig_resolution is exclusive, max_orig_resolution is inclusive
        return self.min_orig_resolution < orig_resolution <= self.max_orig_resolution

    def has_orig_resolution_filter(self) -> bool:
        return not (self.min_orig_resolution == 0.0 and self.max_orig_resolution == float("inf"))

    def update_dataset_image_counts(self):
        for subset in self.subsets:
            subset.img_count = 0

        num_train_images = 0
        num_reg_images = 0
        for image_key, image_info in self.image_data.items():
            subset = self.image_to_subset[image_key]
            subset.img_count += 1

            if image_info.is_reg:
                num_reg_images += image_info.num_repeats
            else:
                num_train_images += image_info.num_repeats

        if hasattr(self, "num_train_images"):
            self.num_train_images = num_train_images
        if hasattr(self, "num_reg_images"):
            self.num_reg_images = num_reg_images

    def filter_registered_images_by_orig_resolution(self) -> int:
        if not self.has_orig_resolution_filter():
            return 0

        filtered_count = 0
        for image_key, image_info in list(self.image_data.items()):
            if self.check_orig_resolution(image_info.image_size):
                continue

            del self.image_data[image_key]
            del self.image_to_subset[image_key]
            filtered_count += 1

        if filtered_count > 0:
            self.update_dataset_image_counts()

        return filtered_count

'''

# Insert after the adjust_min_max_bucket_reso_by_steps method ends
src = src.replace(
    "        return min_bucket_reso, max_bucket_reso\n"
    "\n"
    "    def set_seed(",
    "        return min_bucket_reso, max_bucket_reso\n"
    + NEW_BASEDATASET_METHODS
    + "    def set_seed(",
    1,
)

# 4. Add filter call in make_buckets (after loading image sizes)
src = src.replace(
    "            if info.image_size is None:\n"
    "                info.image_size = self.get_image_size(info.absolute_path)\n"
    "\n"
    "        # # run in parallel",
    "            if info.image_size is None:\n"
    "                info.image_size = self.get_image_size(info.absolute_path)\n"
    "\n"
    "        filtered_count = self.filter_registered_images_by_orig_resolution()\n"
    "        if filtered_count > 0:\n"
    "            logger.info(f\"filtered {filtered_count} images by original resolution\")\n"
    "\n"
    "        # # run in parallel",
    1,
)

# 5. Fix caption cache lookup bug in DreamBoothDataset
src = src.replace(
    "                captions = [meta[\"caption\"] for meta in metas.values()]\n",
    "                captions = [metas[img_path][\"caption\"] for img_path in img_paths]\n",
    1,
)

# 6. Add rebalance_regularization_images and filter override to DreamBoothDataset
#    (the "buggy" version: duplicate loop in rebalance, and update_counts called twice)
DREAMBOOTH_NEW_METHODS = '''    def rebalance_regularization_images(self):
        if not self.is_training_dataset:
            return

        reg_infos: List[Tuple[ImageInfo, DreamBoothSubset]] = []
        for image_key, image_info in list(self.image_data.items()):
            if not image_info.is_reg:
                continue

            reg_infos.append((image_info, self.image_to_subset[image_key]))
            del self.image_data[image_key]
            del self.image_to_subset[image_key]

        num_train_images = sum(info.num_repeats for info in self.image_data.values())
        if len(reg_infos) == 0:
            return

        for info, subset in reg_infos:
            info.num_repeats = subset.num_repeats

        n = 0
        first_loop = True
        while n < num_train_images:
            for info, subset in reg_infos:
                if first_loop:
                    self.register_image(info, subset)
                    n += info.num_repeats
                else:
                    info.num_repeats += 1
                    n += 1
                if n >= num_train_images:
                    break
            first_loop = False

    def filter_registered_images_by_orig_resolution(self) -> int:
        filtered_count = super().filter_registered_images_by_orig_resolution()

        if filtered_count > 0 and self.is_training_dataset:
            self.rebalance_regularization_images()
            self.update_dataset_image_counts()

        return filtered_count

'''

src = src.replace(
    "class DreamBoothDataset(BaseDataset):\n"
    "    IMAGE_INFO_CACHE_FILE = \"metadata_cache.json\"\n"
    "\n"
    "    # The is_training_dataset",
    "class DreamBoothDataset(BaseDataset):\n"
    "    IMAGE_INFO_CACHE_FILE = \"metadata_cache.json\"\n"
    "\n"
    + DREAMBOOTH_NEW_METHODS
    + "    # The is_training_dataset",
    1,
)

# 7. Add min/max_orig_resolution to DreamBoothDataset.__init__ signature
src = src.replace(
    "        resize_interpolation: Optional[str],\n"
    "    ) -> None:\n"
    "        super().__init__(resolution, network_multiplier, debug_dataset, resize_interpolation)\n"
    "\n"
    "        assert resolution is not None",
    "        resize_interpolation: Optional[str],\n"
    "        min_orig_resolution: Optional[float] = None,\n"
    "        max_orig_resolution: Optional[float] = None,\n"
    "    ) -> None:\n"
    "        super().__init__(\n"
    "            resolution,\n"
    "            network_multiplier,\n"
    "            debug_dataset,\n"
    "            resize_interpolation,\n"
    "            min_orig_resolution,\n"
    "            max_orig_resolution,\n"
    "        )\n"
    "\n"
    "        assert resolution is not None",
    1,
)

# 8. Replace duplicate balancing loop in DreamBoothDataset.__init__ with explicit version
#    (keeping it duplicated - this is the "buggy" state)
src = src.replace(
    "        if num_reg_images == 0:\n"
    "            logger.warning(\"no regularization images / 正則化画像が見つかりませんでした\")\n"
    "        else:\n"
    "            # num_repeatsを計算する：どうせ大した数ではないのでループで処理する\n"
    "            n = 0\n"
    "            first_loop = True\n"
    "            while n < num_train_images:\n"
    "                for info, subset in reg_infos:\n"
    "                    if first_loop:\n"
    "                        self.register_image(info, subset)\n"
    "                        n += info.num_repeats\n"
    "                    else:\n"
    "                        info.num_repeats += 1  # rewrite registered info\n"
    "                        n += 1\n"
    "                    if n >= num_train_images:\n"
    "                        break\n"
    "                first_loop = False\n"
    "\n"
    "        self.num_reg_images = num_reg_images",
    "        if num_reg_images == 0:\n"
    "            logger.warning(\"no regularization images / 正則化画像が見つかりませんでした\")\n"
    "        else:\n"
    "            # num_repeatsを計算する：どうせ大した数ではないのでループで処理する\n"
    "            n = 0\n"
    "            first_loop = True\n"
    "            while n < num_train_images:\n"
    "                for info, subset in reg_infos:\n"
    "                    if first_loop:\n"
    "                        self.register_image(info, subset)\n"
    "                        n += info.num_repeats\n"
    "                    else:\n"
    "                        info.num_repeats += 1  # rewrite registered info\n"
    "                        n += 1\n"
    "                    if n >= num_train_images:\n"
    "                        break\n"
    "                first_loop = False\n"
    "\n"
    "        self.num_reg_images = num_reg_images",
    1,
)

# 9. Add min/max_orig_resolution to FineTuningDataset.__init__ signature
src = src.replace(
    "        resize_interpolation: Optional[str],\n"
    "    ) -> None:\n"
    "        super().__init__(resolution, network_multiplier, debug_dataset, resize_interpolation)\n"
    "\n"
    "        self.batch_size = batch_size\n"
    "        self.size = min(self.width, self.height)  # 短いほう\n"
    "        self.latents_cache = None\n"
    "\n"
    "        self.enable_bucket = enable_bucket\n",
    "        resize_interpolation: Optional[str],\n"
    "        min_orig_resolution: Optional[float] = None,\n"
    "        max_orig_resolution: Optional[float] = None,\n"
    "    ) -> None:\n"
    "        super().__init__(\n"
    "            resolution,\n"
    "            network_multiplier,\n"
    "            debug_dataset,\n"
    "            resize_interpolation,\n"
    "            min_orig_resolution,\n"
    "            max_orig_resolution,\n"
    "        )\n"
    "\n"
    "        self.batch_size = batch_size\n"
    "        self.size = min(self.width, self.height)  # 短いほう\n"
    "        self.latents_cache = None\n"
    "\n"
    "        self.enable_bucket = enable_bucket\n",
    1,
)

# 10. Add min/max_orig_resolution to ControlNetDataset.__init__ signature
src = src.replace(
    "        resize_interpolation: Optional[str] = None,\n"
    "    ) -> None:\n"
    "        super().__init__(resolution, network_multiplier, debug_dataset, resize_interpolation)\n"
    "\n"
    "        db_subsets = []",
    "        resize_interpolation: Optional[str] = None,\n"
    "        min_orig_resolution: float = 0.0,\n"
    "        max_orig_resolution: float = float(\"inf\"),\n"
    "    ) -> None:\n"
    "        super().__init__(\n"
    "            resolution,\n"
    "            network_multiplier,\n"
    "            debug_dataset,\n"
    "            resize_interpolation,\n"
    "            min_orig_resolution,\n"
    "            max_orig_resolution,\n"
    "        )\n"
    "\n"
    "        db_subsets = []",
    1,
)

# 11. Pass min/max_orig_resolution to DreamBooth delegate in ControlNetDataset
src = src.replace(
    "            resize_interpolation,\n"
    "        )\n"
    "\n"
    "        # config_util等から参照される値をいれておく",
    "            resize_interpolation,\n"
    "            min_orig_resolution,\n"
    "            max_orig_resolution,\n"
    "        )\n"
    "\n"
    "        # config_util等から参照される値をいれておく",
    1,
)

# 12. Update ControlNetDataset conditioning image validation to handle filter case
src = src.replace(
    "        assert (\n"
    "            len(missing_imgs) == 0\n"
    "        ), f\"missing conditioning data for {len(missing_imgs)} images / 制御用画像が見つかりませんでした: {missing_imgs}\"\n"
    "        assert (\n"
    "            len(extra_imgs) == 0\n"
    "        ), f\"extra conditioning data for {len(extra_imgs)} images / 余分な制御用画像があります: {extra_imgs}\"\n"
    "\n"
    "        self.conditioning_image_transforms",
    "        if not self.has_orig_resolution_filter():\n"
    "            assert (\n"
    "                len(missing_imgs) == 0\n"
    "            ), f\"missing conditioning data for {len(missing_imgs)} images / 制御用画像が見つかりませんでした: {missing_imgs}\"\n"
    "            assert (\n"
    "                len(extra_imgs) == 0\n"
    "            ), f\"extra conditioning data for {len(extra_imgs)} images / 余分な制御用画像があります: {extra_imgs}\"\n"
    "        else:\n"
    "            if len(missing_imgs) > 0:\n"
    "                logger.warning(\n"
    "                    f\"skip early validation for {len(missing_imgs)} missing conditioning images because original-resolution filtering is enabled\"\n"
    "                    + f\" / 元画像解像度フィルタが有効なため、{len(missing_imgs)}枚の不足した制御用画像の事前検証をスキップします\"\n"
    "                )\n"
    "            if len(extra_imgs) > 0:\n"
    "                logger.warning(\n"
    "                    f\"ignore {len(extra_imgs)} extra conditioning images because original-resolution filtering is enabled\"\n"
    "                    + f\" / 元画像解像度フィルタが有効なため、{len(extra_imgs)}枚の余分な制御用画像を無視します\"\n"
    "                )\n"
    "\n"
    "        self.conditioning_image_transforms",
    1,
)

# 13. Update ControlNetDataset.make_buckets to add missing-image check and sync counts
src = src.replace(
    "    def make_buckets(self):\n"
    "        self.dreambooth_dataset_delegate.make_buckets()\n"
    "        self.bucket_manager = self.dreambooth_dataset_delegate.bucket_manager\n"
    "        self.buckets_indices = self.dreambooth_dataset_delegate.buckets_indices\n",
    "    def make_buckets(self):\n"
    "        self.dreambooth_dataset_delegate.make_buckets()\n"
    "\n"
    "        missing_imgs = []\n"
    "        for info in self.dreambooth_dataset_delegate.image_data.values():\n"
    "            if info.cond_img_path is None:\n"
    "                missing_imgs.append(os.path.splitext(os.path.basename(info.absolute_path))[0])\n"
    "        assert (\n"
    "            len(missing_imgs) == 0\n"
    "        ), f\"missing conditioning data for {len(missing_imgs)} images / 制御用画像が見つかりませんでした: {missing_imgs}\"\n"
    "\n"
    "        self.bucket_manager = self.dreambooth_dataset_delegate.bucket_manager\n"
    "        self.buckets_indices = self.dreambooth_dataset_delegate.buckets_indices\n"
    "        self.num_train_images = self.dreambooth_dataset_delegate.num_train_images\n"
    "        self.num_reg_images = self.dreambooth_dataset_delegate.num_reg_images\n",
    1,
)

# 14. Add CLI args for min/max_orig_resolution
src = src.replace(
    '        "--bucket_reso_steps",\n'
    "        type=int,\n",
    '        "--min_orig_resolution",\n'
    "        type=float,\n"
    '        default=0.0,\n'
    '        help="minimum original resolution for images (exclusive), defined by sqrt(width * height) before scaling"\n'
    '        " / 画像の元解像度の下限（排他的）。リサイズ前のsqrt(width * height)で判定します",\n'
    "    )\n"
    "    parser.add_argument(\n"
    '        "--max_orig_resolution",\n'
    "        type=float,\n"
    '        default=float("inf"),\n'
    '        help="maximum original resolution for images (inclusive), defined by sqrt(width * height) before scaling"\n'
    '        " / 画像の元解像度の上限（包含的）。リサイズ前のsqrt(width * height)で判定します",\n'
    "    )\n"
    "    parser.add_argument(\n"
    '        "--bucket_reso_steps",\n'
    "        type=int,\n",
    1,
)

with open("library/train_util.py", "w", encoding="utf-8") as f:
    f.write(src)

print("train_util.py patched")

# ── train_network.py ──────────────────────────────────────────────────────────

with open("train_network.py", "r", encoding="utf-8") as f:
    src = f.read()

# Add min/max_orig_resolution to dataset info dict
src = src.replace(
    '                    "min_bucket_reso": dataset.min_bucket_reso,\n'
    '                    "max_bucket_reso": dataset.max_bucket_reso,\n'
    '                    "tag_frequency": dataset.tag_frequency,\n',
    '                    "min_bucket_reso": dataset.min_bucket_reso,\n'
    '                    "max_bucket_reso": dataset.max_bucket_reso,\n'
    '                    "min_orig_resolution": dataset.min_orig_resolution,\n'
    '                    "max_orig_resolution": dataset.max_orig_resolution,\n'
    '                    "tag_frequency": dataset.tag_frequency,\n',
    1,
)

# Add ss_min/max_orig_resolution to metadata
src = src.replace(
    '                    "ss_min_bucket_reso": dataset.min_bucket_reso,\n'
    '                    "ss_max_bucket_reso": dataset.max_bucket_reso,\n',
    '                    "ss_min_bucket_reso": dataset.min_bucket_reso,\n'
    '                    "ss_max_bucket_reso": dataset.max_bucket_reso,\n'
    '                    "ss_min_orig_resolution": dataset.min_orig_resolution,\n'
    '                    "ss_max_orig_resolution": dataset.max_orig_resolution,\n',
    1,
)

with open("train_network.py", "w", encoding="utf-8") as f:
    f.write(src)

print("train_network.py patched")

# ── Verify syntax ─────────────────────────────────────────────────────────────
import py_compile, sys
errors = []
for path in ["library/config_util.py", "library/train_util.py", "train_network.py"]:
    try:
        py_compile.compile(path, doraise=True)
        print(f"OK: {path}")
    except py_compile.PyCompileError as e:
        errors.append(str(e))
        print(f"SYNTAX ERROR: {e}")

if errors:
    sys.exit(1)
print("All files patched and verified.")
