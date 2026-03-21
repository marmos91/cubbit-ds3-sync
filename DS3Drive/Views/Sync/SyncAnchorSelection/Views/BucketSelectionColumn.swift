import SwiftUI
import DS3Lib

struct BucketSelectionColumn: View {
    @Environment(SyncAnchorSelectionViewModel.self) var syncAnchorSelectionViewModel: SyncAnchorSelectionViewModel
    
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(syncAnchorSelectionViewModel.buckets, id: \.name) { bucket in
                ColumnSelectionRowView(
                    icon: .bucketIcon,
                    name: bucket.name,
                    selected: syncAnchorSelectionViewModel.selectedBucket == bucket
                ) {
                    let viewModel = syncAnchorSelectionViewModel
                    Task {
                        await viewModel.selectBucket(withName: bucket.name)
                    }
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10.0)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
#Preview {
    BucketSelectionColumn()
        .environment(
            SyncAnchorSelectionViewModel(
                project: PreviewData.project,
                authentication: DS3Authentication.loadFromPersistenceOrCreateNew(),
                buckets: [PreviewData.bucket, PreviewData.secondBucket]
            )
        )
        .frame(width: 300, height: 300)
}
