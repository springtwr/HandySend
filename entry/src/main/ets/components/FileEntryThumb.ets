/**
 * FileEntryThumb.ets — 类型图标 / 图片与视频缩略区（跨页公用组件）
 *
 * 按条目定位、类型与文件名解析展示物：
 * - 图片：自行 open 句柄并用 ImageSource 按展示尺寸解码成 PixelMap（失败回退类型图标）；
 * - 视频：按需异步生成缩略图（AVImageGenerator）后渲染；
 * - 其余类型或解码失败：回退类型图标（与发送页暂存列表、接收历史同源）。
 * 加载时机：条目滚入可视区时加载；详情页首屏之后若干行可按 preloadDelay 提前排队解码，
 * 避免滚动时逐张冒出。详情页可能一次建出数百行，全部同时解码会带来明显的内存与耗时压力。
 * 不落盘任何缩略图缓存（大批量传图时缓存会显著增加应用占用空间）。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { getLogger } from '../utils/Logger';
import { LogDomains } from '../common/LogDomains';
import { DesignTokens } from '../common/DesignTokens';
import { getFileTypeIconResource } from '../utils/FileTypeIconUtil';
import { normalizeFileLocation } from '../utils/FileLocationUtil';
import { generateVideoThumbnail } from '../utils/VideoThumbnailUtil';
import { ensureUriAccess } from '../utils/UriPermission';

const logger = getLogger(LogDomains.TRANSFER, 'HandySend:FileEntryThumb', '缩略图');

@ComponentV2
export struct FileEntryThumb {
  /** 文件定位串（沙箱绝对路径或 file:// URI；空串一律回退类型图标） */
  @Param path: string = ''
  /** 文件 MIME 类型 */
  @Param fileType: string = ''
  /** 文件名（类型缺失时用于推导图标） */
  @Param fileName: string = ''
  /** 是否文本消息语义（选用消息图标） */
  @Param isMessage: boolean = false
  /** 展示边长（vp） */
  @Param thumbSize: number = DesignTokens.size.iconLg
  /** 展示圆角（vp） */
  @Param cornerRadius: number = DesignTokens.radius.sm
  /**
   * 预加载延时（毫秒）：>=0 时在组件出现后延时加载（不要求已滚入可视区）。
   * 详情页据此把首屏之后若干行的缩略图提前排队解码，滚动时不再"逐张冒出"。
   */
  @Param preloadDelay: number = -1
  // 缩略图：条目滚入可视区后加载；未就绪 / 加载失败时为 undefined（显示类型图标）
  @Local previewPixelMap: image.PixelMap | undefined = undefined
  // 防重复加载标记：同一条目只加载一次；加载失败时复位，下次滚入可视区重试
  private requested: boolean = false
  // 加载失败标记：为真时直接显示类型图标（图片/视频加载中显示占位块，避免图标→图片的突兀切换）
  @Local loadFailed: boolean = false
  // 预加载定时器（组件销毁时清理）
  private preloadTimer: number = -1
  // 组件已销毁标记：在途解码晚于销毁返回时直接释放结果，避免显存泄漏
  private disposed: boolean = false

  /**
   * 定位变化（如接收侧在会话终结前才回填文件路径）：丢弃旧结果并重新按需加载，
   * 避免缩略图停留在类型图标；渲染期仍不读盘。
   */
  @Monitor('path')
  onPathChanged(): void {
    if (this.previewPixelMap !== undefined) {
      try {
        this.previewPixelMap.release();
      } catch (_e) {
      }
      this.previewPixelMap = undefined;
    }
    this.requested = false;
    this.loadThumbnail();
  }

  /** 组件出现：预加载行按延时排队解码，其余行仍由可视区触发。 */
  aboutToAppear(): void {
    if (this.preloadDelay < 0) {
      return;
    }
    this.preloadTimer = setTimeout((): void => {
      this.preloadTimer = -1;
      if (this.previewPixelMap === undefined) {
        this.loadThumbnail();
      }
    }, this.preloadDelay);
  }

  /** 组件卸载时释放缩略图显存。 */
  aboutToDisappear(): void {
    this.disposed = true;
    if (this.preloadTimer >= 0) {
      clearTimeout(this.preloadTimer);
      this.preloadTimer = -1;
    }
    if (this.previewPixelMap !== undefined) {
      try {
        this.previewPixelMap.release();
      } catch (_e) {
      }
      this.previewPixelMap = undefined;
    }
  }

  /** 滚入可视区时按需加载一次；已出图或已发起过请求时跳过。 */
  private onVisibleChanged(isVisible: boolean): void {
    if (!isVisible) {
      // 离开可视区不保留"已请求"标记：再次进入时允许对未出图的条目重试
      this.requested = false;
      return;
    }
    if (this.previewPixelMap !== undefined) {
      return;
    }
    // 重新可见时允许重试一次（此前可能因授权未激活等原因失败）
    this.loadFailed = false;
    this.loadThumbnail();
  }

  /** 按类型加载缩略图（渲染期不读盘）。 */
  private loadThumbnail(): void {
    if (this.requested || this.path.length === 0) {
      return;
    }
    this.requested = true;
    if (this.fileType.startsWith('video/')) {
      this.loadVideoThumbnail();
      return;
    }
    this.loadImageThumbnail();
  }

  /**
   * 图片：自行打开句柄并用 ImageSource 解码成指定尺寸的 PixelMap。
   *
   * 不把 `file://media/...` 直接交给 Image 渲染：该路径失败时组件侧拿不到错误码；
   * 自行 open + ImageSource 可读取真实错误，并按 desiredSize 解码（内存可控）。
   */
  private async loadImageThumbnail(): Promise<void> {
    let location = normalizeFileLocation(this.path);
    if (!location.locatable || location.uri.length === 0) {
      // 无法定位即确定出不了图：标记失败以回退类型图标，不能停留在「加载中」占位
      this.requested = false;
      this.loadFailed = true;
      return;
    }
    let side: number = Math.round(this.thumbSize * 2);
    let file: fs.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    try {
      // 访问前激活持久化授权：临时授权可能已超过有效期（与进程是否重启无关）
      await ensureUriAccess(location.uri);
      file = await fs.open(location.uri, fs.OpenMode.READ_ONLY);
      source = image.createImageSource(file.fd);
      // 运行时可能在解码前置阶段返回 undefined（声明类型未覆盖），按不可用处理
      let info: image.ImageInfo | undefined = source.getImageInfoSync(0);
      let targetWidth: number = side;
      let targetHeight: number = side;
      if (info !== undefined && info.size.width > 0 && info.size.height > 0) {
        let scale: number = Math.min(side / info.size.width, side / info.size.height);
        targetWidth = Math.max(1, Math.round(info.size.width * scale));
        targetHeight = Math.max(1, Math.round(info.size.height * scale));
      }
      let options: image.DecodingOptions = {
        desiredSize: { width: targetWidth, height: targetHeight }
      };
      let pixelMap: image.PixelMap = await source.createPixelMap(options);
      if (this.disposed) {
        // 组件已销毁：结果无处展示，直接释放避免显存泄漏
        try {
          pixelMap.release();
        } catch (_e) {
        }
        return;
      }
      this.loadFailed = false;
      this.replacePreviewPixelMap(pixelMap);
    } catch (e) {
      // 失败不锁存：显示类型图标，下次滚入可视区重试（授权激活后即可恢复）
      this.requested = false;
      this.loadFailed = true;
      logger.debug('缩略图解码失败 uri=' + this.path + ' 原因=' + String(e));
    } finally {
      if (source !== undefined) {
        try {
          await source.release();
        } catch (_ce) {
        }
      }
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (_closeErr) {
        }
      }
    }
  }

  /** 覆盖缩略图前释放旧 PixelMap 显存。 */
  private replacePreviewPixelMap(pixelMap: image.PixelMap): void {
    if (this.previewPixelMap !== undefined) {
      try {
        this.previewPixelMap.release();
      } catch (_e) {
      }
    }
    this.previewPixelMap = pixelMap;
  }

  /**
   * 视频：异步生成缩略图；失败静默回退类型图标（生成器内部已捕获异常）。
   *
   * 此处故意把条目定位**原串**直接交给缩略图生成、不做 URI → 本机路径换算：生成器内部以
   * `fs.openSync(source)` 打开，而 `file://` 语义下沙箱与媒体库文件均可经文件基础服务访问，
   * 与发送页暂存列表同一入参形式（该页已证实可用）；换算成本机路径反而会因无直接访问权而失败。
   */
  private loadVideoThumbnail(): void {
    let side: number = Math.round(this.thumbSize * 2);
    generateVideoThumbnail(this.path, side, side).then((pixelMap: image.PixelMap | undefined): void => {
      if (pixelMap === undefined) {
        // 取消/失败不锁存，下次出现时重试
        this.requested = false;
        this.loadFailed = true;
        return;
      }
      if (this.disposed) {
        // 组件已销毁：结果无处展示，直接释放避免显存泄漏
        try {
          pixelMap.release();
        } catch (_e) {
        }
        return;
      }
      this.loadFailed = false;
      this.replacePreviewPixelMap(pixelMap);
    }).catch((_e: Object): void => {
      this.requested = false;
      this.loadFailed = true;
    });
  }

  /**
   * 是否为「图片 / 视频且尚未出图、也未曾失败」的加载中状态。
   * 定位为空即确定不会出图（未落盘 / 记录缺少路径），不算加载中，直接回退类型图标。
   */
  private isMediaLoading(): boolean {
    if (this.loadFailed || this.path.length === 0) {
      return false;
    }
    return this.fileType.startsWith('image/') || this.fileType.startsWith('video/');
  }

  build() {
    Row() {
      if (this.previewPixelMap !== undefined) {
        Image(this.previewPixelMap)
          .width(this.thumbSize)
          .height(this.thumbSize)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.cornerRadius)
      } else if (this.isMediaLoading()) {
        // 加载中的图片 / 视频：先占位，避免类型图标一闪再换成图片的突兀感
        Column()
          .width(this.thumbSize)
          .height(this.thumbSize)
          .borderRadius(this.cornerRadius)
          .backgroundColor($r('app.color.border_light'))
      } else {
        Image(getFileTypeIconResource(this.isMessage, this.fileName, this.fileType))
          .width(this.thumbSize)
          .height(this.thumbSize)
      }
    }
    .width(this.thumbSize)
    .height(this.thumbSize)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .onVisibleAreaChange([0.0, 0.1], (_isExpanding: boolean, currentRatio: number): void => {
      this.onVisibleChanged(currentRatio > 0);
    })
  }
}
