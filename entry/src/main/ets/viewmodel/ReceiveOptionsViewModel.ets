import { picker } from '@kit.CoreFileKit';
import { setDestination, setSaveToGallery } from '../service/AppService';
import { isImage, isVideo, hasDirectoryPath } from '../utils/MimeUtils';
import { PendingRequestFile } from '../model/Types';
import { ReceiveOptionsItemViewModel } from './ReceiveOptionsItemViewModel';

@Observed
export class ReceiveOptionsViewModel {
  public fileItems: Array<ReceiveOptionsItemViewModel> = []
  public destination: string = ''
  public saveToGallery: boolean = true
  public senderAlias: string = ''
  public hasDirectoryPath: boolean = false

  loadOptions(destination: string, saveToGallery: boolean, senderAlias: string, filesJson: string): void {
    this.destination = destination;
    this.saveToGallery = saveToGallery;
    this.senderAlias = senderAlias;

    let entries: Array<PendingRequestFile> = [];
    if (filesJson !== undefined && filesJson.length > 0) {
      try {
        entries = JSON.parse(filesJson) as Array<PendingRequestFile>;
      } catch (_e) {
        entries = [];
      }
    }
    let items: Array<ReceiveOptionsItemViewModel> = [];
    for (let i = 0; i < entries.length; i++) {
      items.push(new ReceiveOptionsItemViewModel(entries[i]));
    }
    this.fileItems = items;

    // Check if any file has directory path
    let hasDir: boolean = false;
    for (let i = 0; i < this.fileItems.length; i++) {
      if (this.fileItems[i].file.fileName !== undefined && hasDirectoryPath(this.fileItems[i].file.fileName)) {
        hasDir = true;
        break;
      }
    }
    this.hasDirectoryPath = hasDir;
  }

  applyQuickAction(action: string): void {
    if (action === 'selectAll') {
      this.selectAll();
    } else if (action === 'deselectAll') {
      this.deselectAll();
    } else if (action === 'onlyImages') {
      this.onlyImages();
    } else if (action === 'onlyVideos') {
      this.onlyVideos();
    }
  }

  resetSelection(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      this.fileItems[i].isSelected = true;
    }
  }

  toggleSelect(index: number, isChecked: boolean): void {
    if (index >= 0 && index < this.fileItems.length) {
      this.fileItems[index].isSelected = isChecked;
    }
  }

  renameFile(index: number, newName: string): void {
    if (index >= 0 && index < this.fileItems.length) {
      this.fileItems[index].file.fileName = newName;
    }
  }

  setSaveToGallery(isOn: boolean): void {
    this.saveToGallery = isOn;
    setSaveToGallery(isOn);
  }

  changeDestination(): void {
    try {
      let documentPicker = new picker.DocumentViewPicker();
      documentPicker.select().then((uris: Array<string>) => {
        if (uris.length > 0) {
          this.destination = uris[0];
          setDestination(uris[0]);
        }
      }).catch((_e: Object) => {
        // User cancelled picker or error
      });
    } catch (_e) {
      // DocumentViewPicker not available
    }
  }

  private selectAll(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      this.fileItems[i].isSelected = true;
    }
  }

  private deselectAll(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      this.fileItems[i].isSelected = false;
    }
  }

  private onlyImages(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      this.fileItems[i].isSelected = isImage(this.fileItems[i].file.fileType);
    }
  }

  private onlyVideos(): void {
    for (let i = 0; i < this.fileItems.length; i++) {
      this.fileItems[i].isSelected = isVideo(this.fileItems[i].file.fileType);
    }
  }
}
