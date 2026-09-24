/**
 * FileEntryThumb.ets — 类型图标 / 图片与视频缩略区（跨页公用组件）
 *
 * 按条目定位、类型与文件名解析展示物：
 * - 图片：异步确认文件存在后以对外 URI（file://）交 Image 渲染；
 * - 视频：异步生成缩略图（AVImageGenerator）后渲染；
 * - 其余类型或解析 / 生成失败：回退类型图标（与发送页暂存列表、接收历史同源）。
 * 条目出现时懒加载一次，渲染期不读盘；同一条目不重复加载。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { DesignTokens } from '../common/DesignTokens';
import { getFileTypeIconResource } from '../utils/FileTypeIconUtil';
import { normalizeFileLocation } from '../utils/FileLocationUtil';
import { generateVideoThumbnail } from '../utils/VideoThumbnailUtil';

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
  // 图片缩略图 URI（file://）：条目出现后异步解析缓存；未就绪 / 非图片 / 文件缺失时为空串
  @Local previewUri: string = ''
  // 视频缩略图：条目出现后异步生成；未就绪 / 生成失败时为 undefined
  @Local previewPixelMap: image.PixelMap | undefined = undefined
  // 防重复加载标记：同一条目只加载一次
  private requested: boolean = false

  /**
   * 定位变化（如接收侧在会话终结前才回填文件路径）：丢弃旧结果并重新按需加载，
   * 避免缩略图停留在类型图标；渲染期仍不读盘。
   */
  @Monitor('path')
  onPathChanged(): void {
    this.previewUri = '';
    this.previewPixelMap = undefined;
    this.requested = false;
    this.loadThumbnail();
  }

  /** 条目出现时按需加载一次（渲染期不读盘；非图片 / 视频或路径为空直接回退图标）。 */
  private loadThumbnail(): void {
    if (this.requested || this.path.length === 0) {
      return;
    }
    this.requested = true;
    if (this.fileType.startsWith('image/')) {
      this.loadImageThumbnail();
      return;
    }
    if (this.fileType.startsWith('video/')) {
      this.loadVideoThumbnail();
    }
  }

  /**
   * 图片：异步确认文件存在后使用对外 URI 直接渲染；文件缺失 / 异常时保持空串回退类型图标。
   *
   * 存在性校验按输入形式（`this.path`）优先路由，原因：条目定位有两种来源——接收侧 / 公共目录的
   * 本机绝对路径，以及发送侧文件选择器返回的 `file://` URI；而文件属性查询接口的参数是应用沙箱
   * 路径，选择器来源文件的换算路径本应用通常无直接访问权，单一按路径校验会使发送侧图片静默回退
   * 类型图标。故输入为 `file://` 时先按 URI 打开取文件描述符属性（与发送链路同一方式），失败再
   * 回退本机路径；输入为绝对路径时先按路径（保持既有行为与顺序），失败再回退 URI。任一方式校验
   * 通过即以 URI 交 Image 渲染。
   */
  private loadImageThumbnail(): void {
    let location = normalizeFileLocation(this.path);
    if (!location.locatable || location.uri.length === 0) {
      return;
    }
    this.verifyByInputForm(location.localPath, location.uri).then((exists: boolean): void => {
      if (exists) {
        this.previewUri = location.uri;
      }
    }).catch((_e: Object): void => {
      // 文件已移动 / 删除等异常——保持空串回退类型图标
    });
  }

  /**
   * 存在性校验：按输入形式优先路由，失败回退另一种方式；任一方式通过即视为存在。
   * 输入为 `file://` 时先按 URI，否则先按本机路径（保持既有行为与顺序）。
   */
  private async verifyByInputForm(localPath: string, uri: string): Promise<boolean> {
    if (this.path.startsWith('file://')) {
      if (await this.verifyByUri(uri)) {
        return true;
      }
      return this.verifyByLocalPath(localPath);
    }
    if (await this.verifyByLocalPath(localPath)) {
      return true;
    }
    return this.verifyByUri(uri);
  }

  /**
   * 按 URI 打开后经文件描述符取属性校验是否为普通文件；正常路径与异常路径都关闭已打开的文件对象，
   * 不泄漏文件描述符。
   */
  private async verifyByUri(uri: string): Promise<boolean> {
    let file: fs.File | undefined = undefined;
    try {
      file = await fs.open(uri, fs.OpenMode.READ_ONLY);
      let stat: fs.Stat = await fs.stat(file.fd);
      return stat.isFile();
    } catch (e) {
      // 打开 / 取属性失败视为该方式校验不通过
      return false;
    } finally {
      if (file !== undefined) {
        try {
          await fs.close(file);
        } catch (_closeErr) {
        }
      }
    }
  }

  /** 按本机路径校验是否为普通文件（保持既有 fs.stat 行为）。 */
  private verifyByLocalPath(localPath: string): Promise<boolean> {
    return fs.stat(localPath).then((stat: fs.Stat): boolean => {
      return stat.isFile();
    }).catch((_e: Object): boolean => {
      return false;
    });
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
      this.previewPixelMap = pixelMap;
    }).catch((_e: Object): void => {
    });
  }

  build() {
    Row() {
      if (this.previewUri.length > 0) {
        Image(this.previewUri)
          .width(this.thumbSize)
          .height(this.thumbSize)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.cornerRadius)
      } else if (this.previewPixelMap !== undefined) {
        Image(this.previewPixelMap)
          .width(this.thumbSize)
          .height(this.thumbSize)
          .objectFit(ImageFit.Cover)
          .borderRadius(this.cornerRadius)
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
    .onAppear(() => {
      this.loadThumbnail();
    })
  }
}
