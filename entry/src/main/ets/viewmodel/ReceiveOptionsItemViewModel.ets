import { PendingRequestFile } from '../model/Types';
import { formatSizeDetailed } from '../utils/FormatUtil';

// Item-level ViewModel wrapping a pending receive file.
// Chosen per the scenario-based list policy (Option B): items are
// modifiable (per-item selection + rename), so each item is wrapped
// instead of exposing the raw DTO to the view.
@Observed
export class ReceiveOptionsItemViewModel {
  public file: PendingRequestFile
  public isSelected: boolean = true

  constructor(file: PendingRequestFile) {
    this.file = file;
    this.isSelected = true;
  }

  get formattedSize(): string {
    return formatSizeDetailed(this.file.size);
  }
}
