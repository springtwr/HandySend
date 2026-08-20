import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { LogEntry, NetworkInterface, NetworkType } from '../../model/Types';
import { getLogger, LogContext } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

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

export function addLog(level: string, message: string): void {
  logs.push({ timestamp: Date.now(), level: level, message: message });
  if (logs.length > 250) {
    // 裁剪到 200 条，保留最近的条目
    logs = logs.slice(-200);
  }
  // hilog 输出现已由 Logger 模块处理；addLog 仅管理内存日志存储
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
    // 获取默认网络用于标记
    let defaultNetHandle = connection.getDefaultNetSync();
    let defaultNetId = defaultNetHandle.netId;

    // 获取所有激活的网络
    let allNets: Array<connection.NetHandle> = connection.getAllNetsSync();

    for (let i = 0; i < allNets.length; i++) {
      let netHandle = allNets[i];

      try {
        // 获取网络能力（判断类型）
        let netCap = connection.getNetCapabilitiesSync(netHandle);

        // 获取连接属性（IP地址等）
        let props = connection.getConnectionPropertiesSync(netHandle);

        // 判断网络类型
        let type = NetworkType.unknown;
        if (netCap.bearerTypes !== undefined) {
          if (netCap.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            type = NetworkType.wifi;
          } else if (netCap.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)) {
            type = NetworkType.cellular;
          } else if (netCap.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
            type = NetworkType.ethernet;
          }
        }

        // 提取IPv4地址
        if (props.linkAddresses !== undefined) {
          for (let j = 0; j < props.linkAddresses.length; j++) {
            let linkAddr = props.linkAddresses[j];
            if (linkAddr.address !== undefined && linkAddr.address.family === 1) {
              let isDefault = (netHandle.netId === defaultNetId);
              result.push({
                ip: linkAddr.address.address,
                prefixLength: linkAddr.prefixLength,
                type: type,
                isDefault: isDefault
              });
            }
          }
        }
      } catch (e) {
      logger.warn('Failed to get network info for netId=' + netHandle.netId + ': ' + JSON.stringify(e));
      }
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
      isDefault: true
    });
  }

  return result;
}

export function updateLocalInterfaces(): void {
  localInterfaces = getAllLocalIps();
  logger.info('Updated local interfaces: ' + localInterfaces.length + ' found');
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
