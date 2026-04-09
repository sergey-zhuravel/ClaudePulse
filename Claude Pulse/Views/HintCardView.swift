//
//  HintCardView.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import SwiftUI
import AppKit

struct HintCardView: View {
    let hint: QuotaSnapshot.UsageHint
    @State private var confirmedIdx: Int? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: hint.symbol)
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text(hint.content)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            
            if !hint.commands.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(hint.commands.enumerated()), id: \.offset) { index, command in
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command.clipboardValue, forType: .string)
                            confirmedIdx = index
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                confirmedIdx = nil
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: confirmedIdx == index ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9))
                                Text(confirmedIdx == index ? "Copied!" : "Copy → \(command.title)")
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.20), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}
