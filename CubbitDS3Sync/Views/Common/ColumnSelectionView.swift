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
                .font(.custom("Nunito", size: 14))
            
            Spacer()
            
            Image(systemName: "chevron.forward")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if self.selected || self.isHover {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(.buttonPrimary), lineWidth: 1)
                    .fill(Color(.buttonPrimary))
            }
        }
        .onHover { hovering in
            self.isHover = hovering
        }
        .onChange(of: self.isHover) {
            DispatchQueue.main.async {
                if self.isHover {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
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
