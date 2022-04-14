import 'dart:math';

import 'package:extended_image/extended_image.dart';
import 'package:flukit/flukit.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/pages/read/read_page_state.dart';
import 'package:jhentai/src/pages/read/widget/eh_photo_view_gallery.dart';
import 'package:jhentai/src/pages/read/widget/eh_scrollable_positioned_list.dart';
import 'package:jhentai/src/pages/read/widget/read_view_helper.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:jhentai/src/utils/log.dart';
import 'package:jhentai/src/utils/size_util.dart';
import 'package:jhentai/src/widget/eh_image.dart';
import 'package:jhentai/src/widget/icon_text_button.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../../service/download_service.dart';
import '../../utils/route_util.dart';

class ReadPage extends StatelessWidget {
  final ReadPageLogic logic = Get.put(ReadPageLogic());
  final ReadPageState state = Get.find<ReadPageLogic>().state;
  final DownloadService downloadService = Get.find();

  ReadPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ReadViewHelper(
        child: Obx(() {
          logic.hideSystemBarIfNeeded(ReadSetting.enableImmersiveMode.isTrue);
          return ReadSetting.readDirection.value == ReadDirection.top2bottom ? _buildListView() : _buildPageView();
        }),
      ),
    );
  }

  Widget _buildListView() {
    /// we need to scale the whole list rather than single image, so assign count = 1.
    return PhotoViewGallery.builder(
      itemCount: 1,
      builder: (context, index) => PhotoViewGalleryPageOptions.customChild(
        scaleStateController: state.photoViewScaleStateController,
        onScaleEnd: logic.onScaleEnd,
        child: EHScrollablePositionedList.separated(
          minCacheExtent: state.mode == 'local' ? 8 * screenHeight : ReadSetting.preloadDistance * screenHeight * 1,
          initialScrollIndex: state.initialIndex,
          itemCount: state.pageCount,
          itemScrollController: state.itemScrollController,
          itemPositionsListener: state.itemPositionsListener,
          itemBuilder: (context, index) =>
              state.mode == 'online' ? _buildItemInOnlineMode(context, index) : _buildItemInLocalMode(context, index),
          separatorBuilder: (BuildContext context, int index) => const Divider(height: 6),
        ),
      ),
    );
  }

  Widget _buildPageView() {
    return EHPhotoViewGallery.builder(
      pageController: state.pageController,
      cacheExtent: ReadSetting.preloadPageCount.value.toDouble(),
      itemCount: state.pageCount,
      onPageChanged: logic.recordReadProgress,
      reverse: ReadSetting.readDirection.value == ReadDirection.right2left,
      builder: (context, index) => PhotoViewGalleryPageOptions.customChild(
        scaleStateController: state.photoViewScaleStateController,
        onScaleEnd: logic.onScaleEnd,
        child: Obx(() {
          Widget item =
              state.mode == 'online' ? _buildItemInOnlineMode(context, index) : _buildItemInLocalMode(context, index);

          if (ReadSetting.enableAutoScaleUp.isTrue) {
            item = Center(child: SingleChildScrollView(child: item));
          }

          return item;
        }),
      ),
    );
  }

  /// online mode: parsing and loading automatically while scrolling
  Widget _buildItemInOnlineMode(BuildContext context, int index) {
    return GetBuilder<ReadPageLogic>(
      id: '$itemId::$index',
      builder: (logic) {
        /// step 1: parse image href if needed. check if thumbnail's info exists, if not, [parse] one page of thumbnails to get
        /// image hrefs.
        if (state.thumbnails[index] == null) {
          if (state.parseImageHrefsState == LoadingState.idle) {
            logic.beginToParseImageHref(index);
          }
          return _buildParsingHrefsIndicator(context, index);
        }

        /// step 2: parse image url.
        if (state.images[index] == null) {
          if (state.parseImageUrlStates[index] == LoadingState.idle) {
            logic.beginToParseImageUrl(index, false);
          }
          return _buildParsingUrlIndicator(context, index);
        }

        /// step 3: use url to load image
        FittedSizes fittedSizes = _getImageFittedSize(state.images[index]!);
        return KeepAliveWrapper(
          child: EHImage.network(
            containerHeight: fittedSizes.destination.height,
            containerWidth: fittedSizes.destination.width,
            galleryImage: state.images[index]!,
            adaptive: true,
            fit: BoxFit.contain,
            loadingWidgetBuilder: (double progress) => _loadingWidgetBuilder(context, index, progress),
            failedWidgetBuilder: (ExtendedImageState state) => _failedWidgetBuilder(context, index, state),
          ),
        );
      },
    );
  }

  /// local mode: wait for download service to parse and download
  Widget _buildItemInLocalMode(BuildContext context, int index) {
    return GetBuilder<DownloadService>(
      id: '$imageId::${state.gid}',
      builder: (_) {
        /// step 1: wait for parsing image's href for this image. But if image's url has been parsed,
        /// we don't need to wait parsing thumbnail.
        if (state.thumbnails[index] == null && state.images[index] == null) {
          return _buildWaitParsingHrefsIndicator(context, index);
        }

        /// step 2: wait for parsing image's url.
        if (state.images[index] == null) {
          return _buildWaitParsingUrlIndicator(context, index);
        }

        /// step 3: use url to load image
        FittedSizes fittedSizes = _getImageFittedSize(state.images[index]!);
        return KeepAliveWrapper(
          child: EHImage.file(
            containerHeight: fittedSizes.destination.height,
            containerWidth: fittedSizes.destination.width,
            galleryImage: state.images[index]!,
            adaptive: true,
            fit: BoxFit.contain,
            downloadingWidgetBuilder: () => _downloadingWidgetBuilder(index),
            pausedWidgetBuilder: () => _pausedWidgetBuilder(index),
          ),
        );
      },
    );
  }

  /// wait for [logic] to parse image href in online mode
  Widget _buildParsingHrefsIndicator(BuildContext context, int index) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showReParseBottomSheet(context, () => logic.beginToParseImageHref(index)),
      child: SizedBox(
        height: screenHeight / 2,
        child: GetBuilder<ReadPageLogic>(
          id: parseImageHrefsStateId,
          builder: (logic) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                LoadingStateIndicator(
                  userCupertinoIndicator: false,
                  loadingState: state.parseImageHrefsState,
                  idleWidget: const CircularProgressIndicator(),
                  errorWidget: const Icon(Icons.warning, color: Colors.yellow),
                ),
                Text(
                  state.parseImageHrefsState == LoadingState.error ? state.errorMsg[index]! : 'parsingPage'.tr,
                  style: state.readPageTextStyle(),
                ).marginOnly(top: 8),
                Text(index.toString(), style: state.readPageTextStyle()).marginOnly(top: 4),
              ],
            );
          },
        ),
      ),
    );
  }

  /// wait for [logic] to parse image url in online mode
  Widget _buildParsingUrlIndicator(BuildContext context, int index) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showReParseBottomSheet(context, () => logic.beginToParseImageUrl(index, true)),
      child: SizedBox(
        height: screenHeight / 2,
        child: GetBuilder<ReadPageLogic>(
            id: '$parseImageUrlStateId::$index',
            builder: (logic) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LoadingStateIndicator(
                    userCupertinoIndicator: false,
                    loadingState: state.parseImageUrlStates[index],
                    idleWidget: const CircularProgressIndicator(),
                    errorWidget: const Icon(Icons.warning, color: Colors.yellow),
                  ),
                  Text(
                    state.parseImageUrlStates[index] == LoadingState.error ? state.errorMsg[index]! : 'parsingURL'.tr,
                    style: state.readPageTextStyle(),
                  ).marginOnly(top: 8),
                  Text(index.toString(), style: state.readPageTextStyle()).marginOnly(top: 4),
                ],
              );
            }),
      ),
    );
  }

  /// wait for [DownloadService] to parse image href in local mode
  Widget _buildWaitParsingHrefsIndicator(BuildContext context, int index) {
    DownloadStatus downloadStatus = downloadService.gid2downloadProgress[state.gid]!.downloadStatus;

    return SizedBox(
      height: screenHeight / 2,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (downloadStatus == DownloadStatus.downloading) const CircularProgressIndicator(),
          if (downloadStatus == DownloadStatus.paused) const Icon(Icons.pause_circle_outline, color: Colors.white),
          Text(
            downloadStatus == DownloadStatus.downloading ? 'parsingPage'.tr : 'paused'.tr,
            style: state.readPageTextStyle(),
          ).marginOnly(top: 8),
          Text(index.toString(), style: state.readPageTextStyle()).marginOnly(top: 4),
        ],
      ),
    );
  }

  /// wait for [DownloadService] to parse image url in local mode
  Widget _buildWaitParsingUrlIndicator(BuildContext context, int index) {
    DownloadStatus downloadStatus = downloadService.gid2downloadProgress[state.gid]!.downloadStatus;

    return SizedBox(
      height: screenHeight / 2,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (downloadStatus == DownloadStatus.downloading) const CircularProgressIndicator(),
          if (downloadStatus == DownloadStatus.paused) const Icon(Icons.pause_circle_outline, color: Colors.white),
          Text(
            downloadStatus == DownloadStatus.downloading ? 'parsingURL'.tr : 'paused'.tr,
            style: state.readPageTextStyle(),
          ).marginOnly(top: 8),
          Text(index.toString(), style: state.readPageTextStyle()).marginOnly(top: 4),
        ],
      ),
    );
  }

  /// loading for online mode
  Widget _loadingWidgetBuilder(BuildContext context, int index, double progress) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(value: progress),
        Text('loading'.tr, style: state.readPageTextStyle()).marginOnly(top: 8),
        Text(index.toString(), style: state.readPageTextStyle()).marginOnly(top: 4),
      ],
    );
  }

  /// failed for online mode
  Widget _failedWidgetBuilder(BuildContext context, int index, ExtendedImageState state) {
    Log.warning(state.lastException, false);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconTextButton(
          iconData: Icons.error,
          text: Text('networkError'.tr, style: this.state.readPageTextStyle()),
          onPressed: state.reLoadImage,
        ),
        Text(index.toString(), style: this.state.readPageTextStyle()),
      ],
    );
  }

  /// downloaded for local mode
  Widget _downloadingWidgetBuilder(int index) {
    return GetBuilder<DownloadService>(
      id: '$speedComputerId::${state.gid}',
      builder: (_) {
        SpeedComputer speedComputer = downloadService.gid2SpeedComputer[state.gid]!;
        int downloadedBytes = speedComputer.imageDownloadedBytes[index];
        int totalBytes = speedComputer.imageTotalBytes[index];

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(value: max(downloadedBytes / totalBytes, 0.01)),
            Text('downloading'.tr, style: state.readPageTextStyle()).marginOnly(top: 8),
            Text(index.toString(), style: state.readPageTextStyle()),
          ],
        );
      },
    );
  }

  /// paused for local mode
  Widget _pausedWidgetBuilder(int index) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.pause_circle_outline, color: Colors.white),
        Text('paused'.tr, style: state.readPageTextStyle()).marginOnly(top: 8),
        Text(index.toString(), style: state.readPageTextStyle()),
      ],
    );
  }

  FittedSizes _getImageFittedSize(GalleryImage image) {
    return applyBoxFit(
      BoxFit.contain,
      Size(image.width, image.height),
      Size(fullScreenWidth, double.infinity),
    );
  }

  void _showReParseBottomSheet(BuildContext context, ErrorTapCallback callback) {
    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            child: Text('reload'.tr),
            onPressed: () async {
              callback();
              back();
            },
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          child: Text('cancel'.tr),
          onPressed: () => back(),
        ),
      ),
    );
  }
}
