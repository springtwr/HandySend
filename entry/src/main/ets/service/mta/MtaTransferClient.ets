/**
 * MtaTransferClient.ets — MTA 接收端传输客户端
 *
 * 负责与发送方建立 WebSocket 连接、完成版本协商、接收 sendRequest 并回 ack，
 * 以及后续的 HTTPS 流式下载与 ZIP 解压落盘。
 * WS 使用 skipServerCertVerification 跳过自签名证书校验；消息格式 `type:id:name?json`。
 */

import { webSocket, http } from '@kit.NetworkKit';
import { BusinessError, zlib } from '@kit.BasicServicesKit';
import { fileIo as fs, ListFileOptions } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  DownloadProgress,
  MtaTransferEventHandlers,
  ReceiveRequest,
  WsMessage,
  buildWsMessage,
  parseSendRequestPayload,
  parseWsMessage
} from '../../model/mta/MtaReceiveModels';
import { MtaConstants } from './MtaConstants';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaTransfer');

/** 将系统异常转换为可读文本 */
function errorText(e: Object): string {
  let obj = e as Record<string, Object>;
  let codeVal = obj['code'];
  let msgVal = obj['message'];
  if (codeVal !== undefined && msgVal !== undefined) {
    return `[${codeVal}] ${msgVal}`;
  }
  if (e instanceof Error) {
    let err = e as Error;
    return err.message.length > 0 ? err.message : '未知错误';
  }
  return '未知错误';
}

/** 下载并保存结果 */
export class DownloadResult {
  /** 已保存文件的完整路径 */
  savedFiles: Array<string> = [];
  /** 解压落盘的条目数 */
  entryCount: number = 0;
  /** 落盘总字节数 */
  totalBytes: number = 0;
}

/** MTA 接收端传输客户端（WS + HTTPS 下载 + ZIP 解压） */
export class MtaTransferClient {
  /** WebSocket 实例 */
  private ws: webSocket.WebSocket | null = null;
  /** 事件回调 */
  private handlers: MtaTransferEventHandlers | null = null;
  /** 临时文件目录（应用 cacheDir） */
  private cacheDir: string = '';
  /** 是否已取消当前下载 */
  private cancelled: boolean = false;
  /** 当前下载请求实例（取消时销毁） */
  private activeHttp: http.HttpRequest | null = null;

  /** 注入临时目录（应用 cacheDir） */
  setCacheDir(cacheDir: string): void {
    this.cacheDir = cacheDir;
  }

  /** 注入事件回调 */
  setEventHandlers(handlers: MtaTransferEventHandlers): void {
    this.handlers = handlers;
  }

  // ── 连接 ──

  /** 建立 WS 连接（跳过服务端证书校验），open 事件到达时 resolve */
  connect(url: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (this.ws !== null) {
        reject('WebSocket 已存在，请先关闭');
        return;
      }
      let ws = webSocket.createWebSocket();
      this.ws = ws;
      let settled = false;
      let timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(`WS 连接超时（${MtaConstants.WS_CONNECT_TIMEOUT_MS}ms）`);
        }
      }, MtaConstants.WS_CONNECT_TIMEOUT_MS);

      ws.on('open', (err: BusinessError, value: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        if (this.handlers !== null) {
          this.handlers.onWsOpen();
        }
        resolve();
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        this.handleMessage(value);
      });
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        let reason = value !== undefined ? `code=${value.code} reason=${value.reason}` : '未知';
        if (this.handlers !== null) {
          this.handlers.onWsClosed(reason);
        }
      });
      ws.on('error', (err: BusinessError) => {
        let detail = errorText(err) + ' raw=' + JSON.stringify(err);
        if (this.handlers !== null) {
          this.handlers.onError('WS', '连接错误: ' + detail);
        }
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject('WS 连接失败: ' + detail);
        }
      });

      let options: webSocket.WebSocketRequestOptions = {
        skipServerCertVerification: true
      };
      ws.connect(url, options).catch((e: BusinessError) => {
        let detail = errorText(e) + ' raw=' + JSON.stringify(e);
        if (this.handlers !== null) {
          this.handlers.onError('WS', '发起连接失败: ' + detail);
        }
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject('WS 发起连接失败: ' + detail);
        }
      });
    });
  }

  /** 处理收到的 WS 消息：版本协商与 sendRequest */
  private handleMessage(value: string | ArrayBuffer): void {    let text = typeof value === 'string' ? value : new util.TextDecoder().decodeToString(new Uint8Array(value));
    let message = parseWsMessage(text);
    if (message === undefined) {
      if (this.handlers !== null) {
        this.handlers.onError('WS', '消息格式非法: ' + text);
      }
      return;
    }
    if (message.name === 'versionNegotiation') {
      this.handleVersionNegotiation(message);
    } else if (message.name === 'sendRequest') {
      this.handleSendRequest(message);
    } else {
      logger.info(`收到未处理的 WS 消息 name=${message.name} id=${message.id}`);
    }
  }

  /** 处理版本协商：回复 ack（version=1, threadLimit=5） */
  private handleVersionNegotiation(message: WsMessage): void {
    let payload = `{"version":${MtaConstants.PROTOCOL_VERSION},"threadLimit":${MtaConstants.THREAD_LIMIT}}`;
    this.send(buildWsMessage('ack', message.id, 'versionNegotiation', payload));
    if (this.handlers !== null) {
      this.handlers.onVersionNegotiated(MtaConstants.PROTOCOL_VERSION);
    }
  }

  /** 处理接收请求：回复空 ack，并解析出请求信息回调 */
  private handleSendRequest(message: WsMessage): void {
    this.send(buildWsMessage('ack', message.id, 'sendRequest', ''));
    let request: ReceiveRequest | undefined = parseSendRequestPayload(message.payload);
    if (request === undefined) {
      if (this.handlers !== null) {
        this.handlers.onError('WS', 'sendRequest payload 解析失败: ' + message.payload);
      }
      return;
    }
    if (this.handlers !== null) {
      this.handlers.onReceiveRequest(request);
    }
  }

  // ── 主动消息 ──

  /** 接受接收请求：回复 ack:1:sendRequest（等待写入完成） */
  async acceptRequest(): Promise<void> {
    await this.send(buildWsMessage('ack', 1, 'sendRequest', ''));
  }

  /** 拒绝接收请求：回送拒绝状态（等待写入完成） */
  async rejectRequest(): Promise<void> {
    await this.sendStatus(MtaConstants.STATUS_TYPE_REFUSE, MtaConstants.STATUS_REASON_REFUSE);
  }

  /** 发送传输状态（action:99:status?{type,reason}，等待写入完成） */
  async sendStatus(type: number, reason: string): Promise<void> {
    let payload = `{"type":${type},"reason":"${reason}"}`;
    await this.send(buildWsMessage('action', MtaConstants.STATUS_MESSAGE_ID, 'status', payload));
  }

  /** 发送 WS 文本消息并等待写入完成（失败仅记录，不抛出） */
  private send(text: string): Promise<void> {
    let ws = this.ws;
    if (ws === null) {
      logger.warn('WS 未连接，忽略发送: ' + text);
      return Promise.resolve();
    }
    return ws.send(text)
      .then((): void => {
      })
      .catch((e: BusinessError): void => {
        logger.warn('WS 发送失败: ' + errorText(e));
      });
  }

  /** 主动关闭 WS 连接并释放实例 */
  async close(): Promise<void> {
    let ws = this.ws;
    if (ws === null) {
      return;
    }
    this.ws = null;
    try {
      ws.off('open');
      ws.off('message');
      ws.off('close');
      ws.off('error');
      await ws.close();
    } catch (e) {
      logger.warn('WS 关闭失败: ' + errorText(e));
    }
  }

  // ── HTTPS 流式下载 ──

  /** 构造下载 URL：https://<goIp>:<port>/download?taskId=<taskId> */
  private buildDownloadUrl(goIp: string, port: number, taskId: string): string {
    return `https://${goIp}:${port}${MtaConstants.DOWNLOAD_PATH}${taskId}`;
  }

  /** 流式下载 ZIP 到 cacheDir 临时文件，返回临时文件路径 */
  async downloadZip(goIp: string, port: number, taskId: string, totalBytes: number): Promise<string> {
    if (this.cacheDir.length === 0) {
      throw new Error('临时目录未设置');
    }
    this.cancelled = false;
    let tempZip = `${this.cacheDir}/mta_recv_${taskId}.zip`;
    this.deleteIfExists(tempZip);
    let url = this.buildDownloadUrl(goIp, port, taskId);
    let received = 0;
    let file = fs.openSync(tempZip, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    let httpRequest = http.createHttp();
    this.activeHttp = httpRequest;
    httpRequest.on('dataReceive', (data: ArrayBuffer) => {
      if (this.cancelled) {
        return;
      }
      try {
        fs.writeSync(file.fd, data);
      } catch (e) {
        logger.warn('写入临时 ZIP 失败: ' + errorText(e));
      }
      received += data.byteLength;
      let progress = new DownloadProgress();
      progress.receivedBytes = received;
      progress.totalBytes = totalBytes;
      progress.percent = totalBytes > 0 ? Math.min(100, Math.floor(received * 100 / totalBytes)) : 0;
      if (this.handlers !== null) {
        this.handlers.onProgress(progress);
      }
    });
    let header: Record<string, string> = { 'Accept': 'application/zip' };
    let options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      remoteValidation: 'skip',
      connectTimeout: MtaConstants.DOWNLOAD_CONNECT_TIMEOUT_MS,
      readTimeout: MtaConstants.DOWNLOAD_READ_TIMEOUT_MS,
      header: header
    };
    try {
      let code = await httpRequest.requestInStream(url, options);
      if (this.cancelled) {
        throw new Error('下载已取消');
      }
      if (code !== http.ResponseCode.OK) {
        throw new Error(`下载响应码异常: ${code}`);
      }
      return tempZip;
    } finally {
      try {
        fs.closeSync(file);
      } catch (e) {
        logger.warn('关闭临时 ZIP 失败: ' + errorText(e));
      }
      try {
        httpRequest.off('dataReceive');
      } catch (e) {
        logger.warn('反注册 dataReceive 失败: ' + errorText(e));
      }
      httpRequest.destroy();
      this.activeHttp = null;
    }
  }

  // ── 解压与落盘 ──

  /** 解压临时 ZIP 到空临时目录，再把文件搬入目标目录（重名加后缀） */
  async extractAndSave(tempZip: string, taskId: string, targetDir: string): Promise<DownloadResult> {
    let result = new DownloadResult();
    let tempUnzipDir = `${this.cacheDir}/mta_unzip_${taskId}`;
    this.deleteDirIfExists(tempUnzipDir);
    fs.mkdirSync(tempUnzipDir, true);
    await zlib.decompressFile(tempZip, tempUnzipDir);
    this.ensureDir(targetDir);

    let listOptions: ListFileOptions = { recursion: true };
    let relPaths = fs.listFileSync(tempUnzipDir, listOptions);
    let totalBytes = 0;
    try {
      for (let i = 0; i < relPaths.length; i++) {
        if (this.cancelled) {
          throw new Error('保存已取消');
        }
        let rel = relPaths[i];
        let fullPath = tempUnzipDir + rel;
        let stat = fs.statSync(fullPath);
        if (stat.isDirectory()) {
          continue;
        }
        if (result.entryCount >= MtaConstants.MAX_UNZIP_ENTRY_COUNT) {
          throw new Error(`ZIP 条目数超过上限 ${MtaConstants.MAX_UNZIP_ENTRY_COUNT}`);
        }
        totalBytes += stat.size;
        if (totalBytes > MtaConstants.MAX_UNZIP_TOTAL_BYTES) {
          throw new Error('ZIP 解压总大小超过上限');
        }
        // 仅取文件名，天然防路径穿越
        let name = this.baseName(rel);
        let targetPath = this.uniqueTargetPath(targetDir, name);
        fs.copyFileSync(fullPath, targetPath);
        result.savedFiles.push(targetPath);
        result.entryCount = result.entryCount + 1;
        let progress = new DownloadProgress();
        progress.receivedBytes = totalBytes;
        progress.totalBytes = totalBytes;
        progress.percent = 100;
        progress.currentFileName = name;
        if (this.handlers !== null) {
          this.handlers.onProgress(progress);
        }
      }
    } catch (e) {
      // 失败/取消时删除本次已写入目标目录的文件，避免半成品污染
      for (let j = 0; j < result.savedFiles.length; j++) {
        this.deleteIfExists(result.savedFiles[j]);
      }
      result.savedFiles = [];
      throw new Error(String(e));
    }
    result.totalBytes = totalBytes;
    this.deleteIfExists(tempZip);
    this.deleteDirIfExists(tempUnzipDir);
    return result;
  }

  /** 清理指定任务残留的临时 ZIP 与解压目录 */
  cleanupTemp(taskId: string): void {
    this.deleteIfExists(`${this.cacheDir}/mta_recv_${taskId}.zip`);
    this.deleteDirIfExists(`${this.cacheDir}/mta_unzip_${taskId}`);
  }

  /** 取消当前下载/保存 */
  cancelDownload(): void {
    this.cancelled = true;
    let active = this.activeHttp;
    if (active !== null) {
      try {
        active.destroy();
      } catch (e) {
        logger.warn('取消下载失败: ' + errorText(e));
      }
    }
  }

  /** 是否已取消 */
  isCancelled(): boolean {
    return this.cancelled;
  }

  // ── 文件辅助 ──

  /** 路径是否存在（accessSync 返回布尔值，异常仅代表无权限等错误） */
  private fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /** 删除已存在的文件 */
  private deleteIfExists(path: string): void {
    if (!this.fileExists(path)) {
      return;
    }
    try {
      fs.unlinkSync(path);
    } catch (e) {
      logger.warn('删除文件失败 ' + path + ': ' + errorText(e));
    }
  }

  /** 删除已存在的目录（递归） */
  private deleteDirIfExists(path: string): void {
    if (!this.fileExists(path)) {
      return;
    }
    try {
      fs.rmdirSync(path);
    } catch (e) {
      logger.warn('删除目录失败 ' + path + ': ' + errorText(e));
    }
  }

  /** 目录不存在时创建（递归） */
  private ensureDir(path: string): void {
    if (this.fileExists(path)) {
      return;
    }
    try {
      fs.mkdirSync(path, true);
    } catch (e) {
      logger.warn('创建目录失败 ' + path + ': ' + errorText(e));
    }
  }

  /** 取相对路径中的文件名 */
  private baseName(relPath: string): string {
    let index = relPath.lastIndexOf('/');
    return index >= 0 ? relPath.substring(index + 1) : relPath;
  }

  /** 在目标目录中生成不冲突的文件路径（重名加 (n) 后缀） */
  private uniqueTargetPath(dir: string, name: string): string {
    let dot = name.lastIndexOf('.');
    let base = dot > 0 ? name.substring(0, dot) : name;
    let ext = dot > 0 ? name.substring(dot) : '';
    let candidate = `${dir}/${name}`;
    let index = 1;
    while (this.fileExists(candidate)) {
      candidate = `${dir}/${base}(${index})${ext}`;
      index = index + 1;
    }
    return candidate;
  }
}
