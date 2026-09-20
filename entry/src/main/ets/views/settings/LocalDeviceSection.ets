/**
 * LocalDeviceSection.ets — 「本机信息」精简展示
 *
 * 由传输中心顶部入口以 bindSheet 呈现：设备名称、设备指纹与各网卡 IP。
 * 服务状态不再在此展示（归属 LocalSend 分组的服务器状态）。
 */

import { DesignTokens } from '../../common/DesignTokens';
import { subscribe, unsubscribe, getDeviceAlias, getServerFingerprint, getLocalInterfaces } from '../../service/AppService';
import { NetworkInterface } from '../../model/Types';
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

  build() {
    Column() {
      Column() {
        this.infoRow($r('app.string.local_device_alias'), this.alias)
        Divider().color($r('app.color.border_light'))
        this.infoRow($r('app.string.local_device_fingerprint'), this.fingerprint)
        Repeat(this.interfaces)
          .each((ri: RepeatItem<NetworkInterface>) => {
            Divider().color($r('app.color.border_light'))
            this.infoRow(networkTypeLabel(ri.item.type), ri.item.ip)
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
