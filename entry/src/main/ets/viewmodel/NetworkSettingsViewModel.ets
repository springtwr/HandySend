import { NetworkInterface, NetworkType } from '../model/Types';

// 网络设置白/黑名单分组（hasUnsavedChanges 期望状态构建用）
export class WhitelistBlacklist {
  whitelist: Array<string> = []
  blacklist: Array<string> = []
}

// 网络设置业务逻辑（从 NetworkSettingsSection 下沉）：
// 接口排序/比较、白名单/黑名单编辑、脏状态检测。
// View 仅持有展示态（@Local）并调用本 VM 的纯函数，不做业务计算。
@ObservedV2
export class NetworkSettingsViewModel {
  // 解析逗号分隔文本为字符串数组
  parseList(text: string): Array<string> {
    if (text.length === 0) {
      return [];
    }
    let normalized = text.replace(new RegExp('，', 'g'), ',').replace(new RegExp('\\n', 'g'), ',');
    let parts = normalized.split(',');
    let result: Array<string> = [];
    for (let i = 0; i < parts.length; i++) {
      let trimmed = parts[i].trim();
      if (trimmed.length > 0) {
        result.push(trimmed);
      }
    }
    return result;
  }

  // 判断接口列表是否为空（无接口或仅有 0.0.0.0）
  isInterfaceListEmpty(localInterfaces: Array<NetworkInterface>): boolean {
    if (localInterfaces.length === 0) {
      return true;
    }
    if (localInterfaces.length === 1 && localInterfaces[0].ip === '0.0.0.0') {
      return true;
    }
    return false;
  }

  // 网络类型排序优先级：WiFi > 以太网 > 未知 > 蜂窝（蜂窝基本不存在局域网传输场景）
  getNetworkTypePriority(type: NetworkType): number {
    if (type === NetworkType.wifi) {
      return 0;
    } else if (type === NetworkType.ethernet) {
      return 1;
    } else if (type === NetworkType.unknown) {
      return 2;
    } else {
      // cellular 排最低
      return 3;
    }
  }

  // 对接口列表按优先级排序
  sortInterfaces(interfaces: Array<NetworkInterface>): Array<NetworkInterface> {
    let sorted: Array<NetworkInterface> = [];
    for (let i = 0; i < interfaces.length; i++) {
      sorted.push(interfaces[i]);
    }
    for (let i = 0; i < sorted.length - 1; i++) {
      for (let j = i + 1; j < sorted.length; j++) {
        if (this.getNetworkTypePriority(sorted[i].type) > this.getNetworkTypePriority(sorted[j].type)) {
          let temp = sorted[i];
          sorted[i] = sorted[j];
          sorted[j] = temp;
        }
      }
    }
    return sorted;
  }

  // 比较两组接口是否相同（按排序后顺序逐项比较 name+ip+type+isDefault）
  interfacesEqual(a: Array<NetworkInterface>, b: Array<NetworkInterface>): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].name !== b[i].name || a[i].ip !== b[i].ip ||
        a[i].type !== b[i].type || a[i].isDefault !== b[i].isDefault) {
        return false;
      }
    }
    return true;
  }

  // 判断接口是否在黑名单中
  isInterfaceBlacklisted(name: string, localBlacklist: Array<string>): boolean {
    for (let i = 0; i < localBlacklist.length; i++) {
      if (localBlacklist[i] === name) {
        return true;
      }
    }
    return false;
  }

  // 判断接口是否在白名单中（黑名单优先：接口同时在黑名单中视为不在白名单）
  isInterfaceWhitelisted(name: string, localWhitelist: Array<string>, localBlacklist: Array<string>): boolean {
    if (this.isInterfaceBlacklisted(name, localBlacklist)) {
      return false;
    }
    for (let i = 0; i < localWhitelist.length; i++) {
      if (localWhitelist[i] === name) {
        return true;
      }
    }
    return false;
  }

  // 从数组中移除指定元素
  removeFromList(list: Array<string>, item: string): Array<string> {
    let result: Array<string> = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== item) {
        result.push(list[i]);
      }
    }
    return result;
  }

  // 检查弹窗内容是否有未保存的修改
  // 逻辑：计算"期望状态"——存储值中的接口保持存储状态，不在存储值中的活跃接口用默认状态——
  // 然后与 localWhitelist/localBlacklist 比较。新出现的接口用默认值不算修改。
  hasUnsavedChanges(savedWhitelistText: string, savedBlacklistText: string,
    localWhitelist: Array<string>, localBlacklist: Array<string>,
    localInterfaces: Array<NetworkInterface>): boolean {
    let savedWhitelist = this.parseList(savedWhitelistText);
    let savedBlacklist = this.parseList(savedBlacklistText);

    // 计算期望状态
    let expected = new WhitelistBlacklist();
    let savedWhitelistSet: Set<string> = new Set();
    let savedBlacklistSet: Set<string> = new Set();
    for (let i = 0; i < savedWhitelist.length; i++) {
      savedWhitelistSet.add(savedWhitelist[i]);
    }
    for (let i = 0; i < savedBlacklist.length; i++) {
      savedBlacklistSet.add(savedBlacklist[i]);
    }

    // 遍历当前活跃接口，决定每个接口的"期望"状态
    for (let i = 0; i < localInterfaces.length; i++) {
      let name = localInterfaces[i].name;
      if (name.length === 0) {
        continue;
      }
      if (savedWhitelistSet.has(name)) {
        expected.whitelist.push(name);
      } else if (savedBlacklistSet.has(name)) {
        expected.blacklist.push(name);
      } else {
        // 不在存储值中：按默认规则
        if (localInterfaces[i].type === NetworkType.wifi ||
          localInterfaces[i].type === NetworkType.ethernet) {
          expected.whitelist.push(name);
        } else {
          expected.blacklist.push(name);
        }
      }
    }

    // 只比较活跃接口部分（忽略已消失接口的残留存储值）
    if (!this.activeListsEqual(localWhitelist, expected.whitelist, localInterfaces)) {
      return true;
    }
    if (!this.activeListsEqual(localBlacklist, expected.blacklist, localInterfaces)) {
      return true;
    }
    return false;
  }

  // 比较两个列表中"活跃接口名"是否一致（忽略不在当前接口列表中的条目）
  activeListsEqual(a: Array<string>, b: Array<string>,
    localInterfaces: Array<NetworkInterface>): boolean {
    let activeNames: Set<string> = new Set();
    for (let i = 0; i < localInterfaces.length; i++) {
      if (localInterfaces[i].name.length > 0) {
        activeNames.add(localInterfaces[i].name);
      }
    }
    // 收集两列表中活跃接口名的集合
    let setA: Set<string> = new Set();
    let setB: Set<string> = new Set();
    for (let i = 0; i < a.length; i++) {
      if (activeNames.has(a[i])) {
        setA.add(a[i]);
      }
    }
    for (let i = 0; i < b.length; i++) {
      if (activeNames.has(b[i])) {
        setB.add(b[i]);
      }
    }
    if (setA.size !== setB.size) {
      return false;
    }
    // 逐项比较
    let arrA = Array.from(setA);
    for (let i = 0; i < arrA.length; i++) {
      if (!setB.has(arrA[i])) {
        return false;
      }
    }
    return true;
  }
}

export const networkSettingsViewModel: NetworkSettingsViewModel = new NetworkSettingsViewModel();
