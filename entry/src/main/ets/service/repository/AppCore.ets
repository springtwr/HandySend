import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { connection } from '@kit.NetworkKit';
import { LogEntry, NetworkInterface, NetworkType } from '../../model/Types';
import { getLogger, LogContext } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { nativeGetNetworkInterfaces } from '../NativeBridge';
import { NetworkInterfaceInfo } from 'localsend_ohrs';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:AppCore');

// ── 共享运行时上下文 ──

let appContext: common.UIAbilityContext | undefined = undefined;

export function getAppContext(): common.UIAbilityContext | undefined {
  return appContext;
}

export function setAppContext(context: common.UIAbilityContext): void {
  appContext = context;
}

// ── 事件总线（面向 UI 视图模型的变化通知） ──

let changeCallbacks: Array<() => void> = [];

export function subscribe(callback: () => void): void {
  changeCallbacks.push(callback);
}

export function unsubscribe(callback: () => void): void {
  let idx = -1;
  for (let i = 0; i < changeCallbacks.length; i++) {
    if (changeCallbacks[i] === callback) {
      idx = i;
      break;
    }
  }
  if (idx >= 0) {
    let last = changeCallbacks.length - 1;
    changeCallbacks[idx] = changeCallbacks[last];
    changeCallbacks.pop();
  }
}

export function notifyChange(): void {
  for (let i = 0; i < changeCallbacks.length; i++) {
    changeCallbacks[i]();
  }
}

export function triggerRefresh(): void {
  notifyChange();
}

// ── 服务器指纹（由 ServerRepository 拥有的共享运行时状态） ──

let serverFingerprint = '';

export function getServerFingerprint(): string {
  return serverFingerprint;
}

export function setServerFingerprint(fp: string): void {
  serverFingerprint = fp;
}

// ── 日志 ──

let logs: Array<LogEntry> = [];

export function getLogs(): Array<LogEntry> {
  return logs;
}

/**
 * 清空内存日志源数据。HTTP 日志页的"清空"必须调用本函数，
 * 否则仅清空 UI 副本会被后台持续写入的日志立即覆盖（表现为清除无效）。
 */
export function clearLogs(): void {
  logs = [];
}

export function addLog(level: string, message: string): void {
  logs.push({ timestamp: Date.now(), level: level, message: message });
  if (logs.length > 2000) {
    // 裁剪到最近 1800 条，保留最近的条目。
    // 2000 条约占用 0.6–1 MB 内存（消息均长 < 1KB），对手机无压力。
    logs = logs.slice(-1800);
  }
  // hilog 输出现已由 Logger 模块处理；addLog 仅管理内存日志存储
}

/**
 * 将日志文本保存到文件（DOWNLOAD 模式，落盘到用户可见的 Downloads/应用目录）。
 * 纯逻辑：picker + fileUri + fs 写入均在此完成，不弹 Toast（UI 反馈由调用方负责）。
 * @param context UIAbilityContext（picker 构造需要），由 View 传入以保持本模块不自行获取 UI 上下文
 * @param text 待保存的日志文本
 * @throws 保存失败时抛出 BusinessError（含用户取消选择器的错误码，调用方据此区分取消/失败）
 */
export async function saveLogsToFile(context: common.UIAbilityContext, text: string): Promise<void> {
  let date: Date = new Date();
  let pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
  let fileName: string = 'handysend_logs_' + date.getFullYear() + pad(date.getMonth() + 1) + pad(date.getDate()) +
    '_' + pad(date.getHours()) + pad(date.getMinutes()) + pad(date.getSeconds()) + '.txt';
  let saveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
  saveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
  let documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
  let uris: Array<string> = await documentPicker.save(saveOptions);
  if (uris.length === 0) {
    return;
  }
  let dirPath: string = new fileUri.FileUri(uris[0]).path;
  let filePath: string = dirPath + '/' + fileName;
  let file: fs.File = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
  try {
    fs.writeSync(file.fd, text);
    fs.fsyncSync(file.fd);
  } finally {
    fs.closeSync(file);
  }
}

export function shortSid(s: string): string {
  return s.length > 8 ? s.substring(0, 8) : s;
}

// ── 本地网络接口 ──

let localInterfaces: Array<NetworkInterface> = []; // 所有本地网卡

// ── 多网卡网络检测 ──

function getAllLocalIps(): Array<NetworkInterface> {
  let result: Array<NetworkInterface> = [];

  try {
    // 主数据源：Rust 侧 if_addrs 枚举所有有 IP 的网络接口
    let rustInterfaces: Array<NetworkInterfaceInfo> = nativeGetNetworkInterfaces();

    // 辅助数据源：connection API 获取激活网络的类型和默认路由状态
    let defaultNetId = -1;
    let connProps: Array<connection.ConnectionProperties> = [];
    let connBearerTypes: Array<Array<connection.NetBearType>> = [];
    let connNetIds: Array<number> = [];

    try {
      let defaultNetHandle = connection.getDefaultNetSync();
      defaultNetId = defaultNetHandle.netId;

      let allNets: Array<connection.NetHandle> = connection.getAllNetsSync();
      for (let i = 0; i < allNets.length; i++) {
        try {
          let netCap = connection.getNetCapabilitiesSync(allNets[i]);
          let props = connection.getConnectionPropertiesSync(allNets[i]);
          connProps.push(props);
          connBearerTypes.push(netCap.bearerTypes !== undefined ? netCap.bearerTypes : []);
          connNetIds.push(allNets[i].netId);
        } catch (e) {
          logger.warn('获取网络 netId=' + allNets[i].netId + ' 属性失败');
        }
      }
    } catch (e) {
      logger.warn('获取 connection API 网络列表失败: ' + JSON.stringify(e));
    }

    // 交叉匹配：Rust 接口名 ↔ ConnectionProperties.interfaceName
    for (let i = 0; i < rustInterfaces.length; i++) {
      let rustIf = rustInterfaces[i];
      let type = NetworkType.unknown;
      let isDefault = false;

      // 在 connection API 返回的激活网络中查找匹配
      for (let j = 0; j < connProps.length; j++) {
        let props = connProps[j];
        if (props.interfaceName !== undefined && props.interfaceName === rustIf.name) {
          // 匹配成功：从 bearerTypes 推导 type
          let bearerTypes = connBearerTypes[j];
          if (bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            type = NetworkType.wifi;
          } else if (bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)) {
            type = NetworkType.cellular;
          } else if (bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
            type = NetworkType.ethernet;
          }
          // 判断 isDefault
          isDefault = (connNetIds[j] === defaultNetId);
          break;
        }
      }

      result.push({
        ip: rustIf.ip,
        prefixLength: rustIf.prefixLength,
        type: type,
        isDefault: isDefault,
        name: rustIf.name
      });
    }
  } catch (e) {
    logger.error('getAllLocalIps failed: ' + JSON.stringify(e));
  }

  // 如果没有找到任何网卡，返回默认值
  if (result.length === 0) {
    result.push({
      ip: '0.0.0.0',
      prefixLength: 24,
      type: NetworkType.unknown,
      isDefault: true,
      name: ''
    });
  }

  return result;
}

export function updateLocalInterfaces(): void {
  localInterfaces = getAllLocalIps();
  logger.debug('Updated local interfaces: ' + localInterfaces.length + ' found');
}

export function getLocalIp(): string {
  // 文件分享优先使用 WiFi 而非蜂窝网络——局域网对端只能访问 WiFi IP
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].type === 'wifi') {
      return localInterfaces[i].ip;
    }
  }
  // 回退：默认网络
  for (let i = 0; i < localInterfaces.length; i++) {
    if (localInterfaces[i].isDefault) {
      return localInterfaces[i].ip;
    }
  }
  // 最后手段：第一个网卡
  if (localInterfaces.length > 0) {
    return localInterfaces[0].ip;
  }
  return '0.0.0.0';
}

export function getLocalInterfaces(): Array<NetworkInterface> {
  return localInterfaces;
}
