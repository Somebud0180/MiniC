//
//  SettingsView.swift
//  Mini C
//
//  Created by Ethan John Lagera on 9/25/26.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Image("Icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                        
                        Text("Mini C")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Manage your settings here. Change the visible quick keys and how the app behaves.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
