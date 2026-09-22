/**
 * LocalDeviceSection.ets — 「本机信息」精简展示
 *
 * 由任务顶部入口以 bindSheet 呈现：设备名称、设备指纹与各网卡 IP。
 * 服务状态不再在此展示（归属 LocalSend 分组的服务器状态）。
 */

import { DesignTokens } from '../../common/DesignTokens';
import {
  subscribe,
  unsubscribe,
  getDeviceAlias,
  getServerFingerprint,
  getLocalInterfaces
} from '../../service/AppService';
import { NetworkInterface, NetworkType } from '../../model/Types';
import { networkTypeLabel } from '../../utils/NetworkPresentation';

@ComponentV2
export struct LocalDeviceSection {
  @Local private alias: string = ''
  @Local private fingerprint: string = ''
  @Local private interfaces: Array<NetworkInterface> = []
  private refreshCallback: () => void = (): void => {
  }

  aboutToAppear(): void {
    this.refreshCallback = (): void => {
      this.refresh();
    };
    subscribe(this.refreshCallback);
    this.refresh();
  }

  aboutToDisappear(): void {
    unsubscribe(this.refreshCallback);
  }

  private refresh(): void {
    this.alias = getDeviceAlias();
    this.fingerprint = getServerFingerprint();
    let list: Array<NetworkInterface> = getLocalInterfaces();
    let result: Array<NetworkInterface> = [];
    for (let i = 0; i < list.length; i++) {
      // 仅保留有实际 IP 的网卡，并按 IP 去重（同一网卡多地址场景）
      if (list[i].ip.length === 0) {
        continue;
      }
      let duplicated: boolean = false;
      for (let k = 0; k < result.length; k++) {
        if (result[k].ip === list[i].ip) {
          duplicated = true;
          break;
        }
      }
      if (!duplicated) {
        result.push(list[i]);
      }
    }
    this.interfaces = result;
  }

  /** 单行信息（标签 + 值，右对齐）：昵称等短字段使用。 */
  @Builder
  infoRow(label: ResourceStr, value: string) {
    Row({ space: DesignTokens.space.sm }) {
      Text(label)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      Text(value.length > 0 ? value : $r('app.string.session_detail_placeholder'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '62%' })
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
  }

  /** 网络类型文字徽标（复用既有网络类型文案）。 */
  @Builder
  networkBadge(type: NetworkType) {
    Text(networkTypeLabel(type))
      .fontSize(DesignTokens.font.bodyS)
      .fontColor($r('app.color.ip_blue_text'))
      .backgroundColor($r('app.color.accent_blue_bg'))
      .padding({
        left: DesignTokens.space.tiny,
        right: DesignTokens.space.tiny,
        top: DesignTokens.space.mini,
        bottom: DesignTokens.space.mini
      })
      .borderRadius(DesignTokens.radius.sm)
      .maxLines(1)
  }

  /** 网卡行：接口名 + 网络类型文字徽标 + IP（单行呈现）。 */
  @Builder
  interfaceRow(item: NetworkInterface) {
    Row({ space: DesignTokens.space.tiny }) {
      Text(item.name.length > 0 ? item.name : $r('app.string.session_detail_placeholder'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      this.networkBadge(item.type)
      Text(item.ip)
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
  }

  /** 设备指纹行：与 infoRow 一致的「标签左 + 值右」，值右对齐限宽；完整展示不截断（允许按字符换行）。 */
  @Builder
  fingerprintRow() {
    Row({ space: DesignTokens.space.sm }) {
      Text($r('app.string.local_device_fingerprint'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
      Text(this.fingerprint.length > 0 ? this.fingerprint : $r('app.string.session_detail_placeholder'))
        .fontSize(DesignTokens.font.bodyM)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.End)
        .constraintSize({ maxWidth: '62%' })
        .wordBreak(WordBreak.BREAK_ALL)
    }
    .width('100%')
    .padding({ top: DesignTokens.space.sm, bottom: DesignTokens.space.sm })
    .constraintSize({ minHeight: DesignTokens.size.thumbSm })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      Column() {
        this.infoRow($r('app.string.local_device_alias'), this.alias)
        Divider().color($r('app.color.border_light'))
        this.fingerprintRow()
        Repeat(this.interfaces)
          .each((ri: RepeatItem<NetworkInterface>) => {
            Divider().color($r('app.color.border_light'))
            this.interfaceRow(ri.item)
          })
          .key((item: NetworkInterface) => item.ip + item.name)
      }
      .width('100%')
      .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md })
      .borderRadius(DesignTokens.radius.lg)
      .backgroundColor($r('app.color.card_background'))
      .border({ width: DesignTokens.component.borderSlim, color: $r('app.color.border_light') })
    }
    .width('100%')
    .padding({ left: DesignTokens.space.md, right: DesignTokens.space.md, bottom: DesignTokens.space.lg })
    .alignItems(HorizontalAlign.Start)
    .id('local_device_sheet')
  }
}
