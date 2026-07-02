import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "ipod")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("PodFlick")
                .font(.title)
            Text("Drop a video here to convert and upload it to your iPod")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
