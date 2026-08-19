import { PendingRequestFile } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';

// Item-level ViewModel wrapping a pending receive file.
// Chosen per the scenario-based list policy (Option B): items are
// modifiable (per-item selection + rename), so each item is wrapped
// instead of exposing the raw DTO to the view.
@ObservedV2
export class ReceiveOptionsItemViewModel {
  @Trace public file: PendingRequestFile
  @Trace public isSelected: boolean = true

  constructor(file: PendingRequestFile) {
    this.file = file;
    this.isSelected = true;
  }

  get formattedSize(): string {
    return formatSizeDetailed(this.file.size);
  }
}
