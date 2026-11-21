/**
 * ServerRunConfig.ets — LocalSend 运行配置快照与待生效判定
 *
 * 服务器启动时记录实际生效的配置；UI 用“当前设置 ≠ 运行配置”判断待生效项。
 * 服务未运行或没有快照时返回空：下次启动会直接读取最新设置。
 */

export interface ServerRunConfig {
  alias: string;
  deviceType: string;
  deviceModel: string;
  port: number;
  useHttps: boolean;
  pin: string;
  multicastGroup: string;
  discoveryTimeout: number;
}

export enum ServerPendingReason {
  alias = 'alias',
  deviceType = 'deviceType',
  deviceModel = 'deviceModel',
  port = 'port',
  https = 'https',
  pin = 'pin',
  multicast = 'multicast',
  discoveryTimeout = 'discoveryTimeout'
}

/** 比较运行配置与当前配置，返回需要重启才能生效的项。 */
export function diffServerRunConfig(running: ServerRunConfig,
  current: ServerRunConfig): Array<ServerPendingReason> {
  let result: Array<ServerPendingReason> = [];
  if (running.alias !== current.alias) {
    result.push(ServerPendingReason.alias);
  }
  if (running.deviceType !== current.deviceType) {
    result.push(ServerPendingReason.deviceType);
  }
  if (running.deviceModel !== current.deviceModel) {
    result.push(ServerPendingReason.deviceModel);
  }
  if (running.port !== current.port) {
    result.push(ServerPendingReason.port);
  }
  if (running.useHttps !== current.useHttps) {
    result.push(ServerPendingReason.https);
  }
  if (running.pin !== current.pin) {
    result.push(ServerPendingReason.pin);
  }
  if (running.multicastGroup !== current.multicastGroup) {
    result.push(ServerPendingReason.multicast);
  }
  if (running.discoveryTimeout !== current.discoveryTimeout) {
    result.push(ServerPendingReason.discoveryTimeout);
  }
  return result;
}

/** 服务未运行（无快照）时返回空，避免把停止状态误报成待重启。 */
export function computePendingReasons(running: ServerRunConfig | undefined,
  current: ServerRunConfig): Array<ServerPendingReason> {
  if (running === undefined) {
    return [];
  }
  return diffServerRunConfig(running, current);
}

/** 是否只有昵称一项待生效。 */
export function isAliasOnlyPending(reasons: Array<ServerPendingReason>): boolean {
  return reasons.length === 1 && reasons[0] === ServerPendingReason.alias;
}

/** 待生效项中是否包含昵称。 */
export function isAliasPending(reasons: Array<ServerPendingReason>): boolean {
  return reasons.indexOf(ServerPendingReason.alias) >= 0;
}
