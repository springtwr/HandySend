import { NetworkInterface, NetworkType } from '../model/Types';
import { isInterfaceEnabled as computeInterfaceEnabled } from '../utils/NetworkInterfaceRules';

// 网络设置白/黑名单分组（hasUnsavedChanges 期望状态构建用）
class WhitelistBlacklist {
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

  // 网络类型排序优先级：WiFi > 以太网 > VPN > 容器网桥 > 未知 > 蜂窝
  // （蜂窝基本不存在局域网传输场景，排最低）
  getNetworkTypePriority(type: NetworkType): number {
    if (type === NetworkType.wifi) {
      return 0;
    } else if (type === NetworkType.ethernet) {
      return 1;
    } else if (type === NetworkType.vpn) {
      return 2;
    } else if (type === NetworkType.bridge) {
      return 3;
    } else if (type === NetworkType.unknown) {
      return 4;
    } else {
      // cellular 排最低
      return 5;
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

  // 判断接口是否在指定列表中
  isInList(name: string, list: Array<string>): boolean {
    for (let i = 0; i < list.length; i++) {
      if (list[i] === name) {
        return true;
      }
    }
    return false;
  }

  // 判断接口是否启用（参与发现与接收）：黑名单优先，其次白名单，
  // 两者都未列出时按类型取默认（WiFi/以太网放行）。规则见 utils/NetworkInterfaceRules。
  isInterfaceEnabled(name: string, type: NetworkType,
    localWhitelist: Array<string>, localBlacklist: Array<string>): boolean {
    return computeInterfaceEnabled(name, type, localWhitelist, localBlacklist);
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

  // 检查弹窗内容是否有未保存的修改。
  // 期望状态 = 存储值中仍然活跃的接口；新接口的默认状态不落存储，两处都不出现，
  // 因此不会误报为修改。再与 localWhitelist/localBlacklist 比较。
  hasUnsavedChanges(savedWhitelistText: string, savedBlacklistText: string,
    localWhitelist: Array<string>, localBlacklist: Array<string>,
    localInterfaces: Array<NetworkInterface>): boolean {
    let savedWhitelist = this.parseList(savedWhitelistText);
    let savedBlacklist = this.parseList(savedBlacklistText);

    // 计算期望状态
    let expected = new WhitelistBlacklist();
    for (let i = 0; i < localInterfaces.length; i++) {
      let name = localInterfaces[i].name;
      if (name.length === 0) {
        continue;
      }
      if (this.isInList(name, savedWhitelist)) {
        expected.whitelist.push(name);
      } else if (this.isInList(name, savedBlacklist)) {
        expected.blacklist.push(name);
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
