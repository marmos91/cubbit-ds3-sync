import SwiftUI

struct ColumnSelectionRowView: View {
    var icon: ImageResource
    var name: String
    var selected: Bool
    
    var onBucketSelected: (() -> Void)?
    @State var isHover: Bool = false
    
    var body: some View {
        HStack {
            Image(icon)
                .padding(.horizontal, 1)
         
            Text(name)
                .font(DS3Typography.body)
            
            Spacer()
            
            Image(systemName: "chevron.forward")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if self.selected || self.isHover {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.accentColor, lineWidth: 1)
                    .fill(Color.accentColor)
            }
        }
        .onHover { hovering in
            self.isHover = hovering
        }
        .pointingHandCursor()
        .onTapGesture {
            onBucketSelected?()
        }
    }
}

#Preview {
    VStack {
        ColumnSelectionRowView(
            icon: .bucketIcon,
            name: "bucket-1",
            selected: true
        )
        ColumnSelectionRowView(
            icon: .folderIcon,
            name: "bucket-2",
            selected: false
        )
    }.padding()
}
