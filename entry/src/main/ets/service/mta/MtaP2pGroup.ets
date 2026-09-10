/**
 * MtaP2pGroup.ets — MTA 发送端 WiFi Direct 建组
 *
 * 发送端创建 WiFi Direct 群组（DIRECT- 前缀 + 随机口令），订阅 p2pConnectionChange 取 GO IP，
 * 通过 getCurrentGroup() 读取群组 SSID / 口令 / 本机 p2p0 MAC（ownerInfo.deviceAddress），
 * 结束或复位时 removeGroup()。GO IP 缺失时以协议常量兜底。与接收端 MtaP2pConnector 完全独立。
 */

import { wifiManager } from '@kit.ConnectivityKit';
import { MtaGroupInfo, MtaP2pGroupEventHandlers } from '../../model/mta/MtaSendModels';
import { MtaConstants } from './MtaConstants';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';

const logger = getLogger(LogDomains.NETWORK, 'HandySend:MtaP2pGroup');

/** 将系统同步调用异常转换为可读文本 */
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

/** MTA 发送端 WiFi Direct 群组管理器 */
export class MtaP2pGroup {
  /** 事件回调集合（服务注入） */
  private handlers: MtaP2pGroupEventHandlers | null = null;
  /** 最近一次 p2pConnectionChange 给出的 GO IP */
  private goIp: string = '';
  /** 是否注册了 p2pConnectionChange 事件 */
  private eventsRegistered: boolean = false;

  // ── 事件注册 / 反注册 ──

  /** 注册 p2pConnectionChange 事件 */
  registerEvents(handlers: MtaP2pGroupEventHandlers): void {
    if (this.eventsRegistered) {
      this.unregisterEvents();
    }
    this.handlers = handlers;
    try {
      wifiManager.on('p2pConnectionChange', (info: wifiManager.WifiP2pLinkedInfo) => {
        this.handleConnection(info);
      });
      this.eventsRegistered = true;
    } catch (e) {
      logger.warn('p2pConnectionChange 注册失败: ' + errorText(e));
    }
  }

  /** 反注册 p2pConnectionChange 事件 */
  unregisterEvents(): void {
    if (!this.eventsRegistered) {
      return;
    }
    try {
      wifiManager.off('p2pConnectionChange');
    } catch (e) {
      logger.warn('p2pConnectionChange 反注册失败: ' + errorText(e));
    }
    this.eventsRegistered = false;
    this.handlers = null;
  }

  /** 处理 p2pConnectionChange：更新 GO IP 并上报摘要 */
  private handleConnection(info: wifiManager.WifiP2pLinkedInfo): void {
    let addr = info.groupOwnerAddr;
    if (info.connectState === 1 && addr !== undefined && addr.length > 0 && addr !== '0.0.0.0') {
      this.goIp = addr;
    }
    let stateText = info.connectState === 1 ? 'CONNECTED' : 'DISCONNECTED';
    let summary = `connectState=${stateText} isGroupOwner=${info.isGroupOwner} groupOwnerAddr=${addr}`;
    if (this.handlers !== null) {
      this.handlers.onConnectionChange(summary);
      if (this.goIp.length > 0) {
        this.handlers.onGoIp(this.goIp);
      }
    }
  }

  // ── 建组 / 查组 / 删组 ──

  /** 创建 P2P 群组（临时组 netId=-1），失败 reject 错误文本 */
  createGroup(groupName: string, passphrase: string, goBand: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      try {
        let config: wifiManager.WifiP2PConfig = {
          deviceAddress: '',
          netId: -1,
          passphrase: passphrase,
          groupName: groupName,
          goBand: goBand
        };
        wifiManager.createGroup(config);
        resolve();
      } catch (e) {
        reject(errorText(e));
      }
    });
  }

  /** 查询当前群组信息，未建组（错误码 2801000）或查询失败返回 null */
  async getCurrentGroup(): Promise<MtaGroupInfo | null> {
    try {
      let group: wifiManager.WifiP2pGroupInfo = await wifiManager.getCurrentGroup();
      let info = new MtaGroupInfo();
      info.ssid = group.groupName;
      info.psk = group.passphrase;
      info.goIp = group.goIpAddress;
      let owner = group.ownerInfo;
      info.ownerMac = owner === undefined ? '' : owner.deviceAddress;
      let clients = group.clientDevices;
      info.clientCount = clients === undefined ? 0 : clients.length;
      info.frequency = group.frequency;
      if (info.goIp.length === 0) {
        info.goIp = this.goIp;
      }
      return info;
    } catch (e) {
      let obj = e as Record<string, Object>;
      let code = obj['code'];
      if (typeof code === 'number' && code === MtaConstants.GROUP_NOT_FOUND_CODE) {
        return null;
      }
      logger.warn('getCurrentGroup 失败: ' + errorText(e));
      return null;
    }
  }

  /** 轮询等待群组信息就绪（SSID 非空），超时返回最后一次查询结果 */
  async waitGroupReady(timeoutMs: number): Promise<MtaGroupInfo | null> {
    let waited = 0;
    while (waited < timeoutMs) {
      let info = await this.getCurrentGroup();
      if (info !== null && info.ssid.length > 0) {
        return info;
      }
      await this.sleepMs(MtaConstants.GROUP_POLL_INTERVAL_MS);
      waited += MtaConstants.GROUP_POLL_INTERVAL_MS;
    }
    return this.getCurrentGroup();
  }

  /** 删除当前 P2P 群组（本无群组时视为已删除） */
  removeGroup(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      try {
        wifiManager.removeGroup();
        resolve();
      } catch (e) {
        let obj = e as Record<string, Object>;
        let code = obj['code'];
        // 本无群组（2801000）视为已删除；错误码可能是数字或字符串
        if (typeof code === 'number' && code === MtaConstants.GROUP_NOT_FOUND_CODE) {
          resolve();
          return;
        }
        if (typeof code === 'string' && code === `${MtaConstants.GROUP_NOT_FOUND_CODE}`) {
          resolve();
          return;
        }
        reject(errorText(e));
      }
    });
  }

  /** 解析可用 GO IP：事件回调值优先，缺失时用默认网关兜底 */
  getGoIp(): string {
    return this.goIp.length > 0 ? this.goIp : MtaConstants.DEFAULT_GO_IP;
  }

  /** 延时辅助 */
  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /** 释放资源（删组、反注册事件） */
  destroy(): void {
    this.removeGroup().catch((): void => {
    });
    this.unregisterEvents();
  }
}
