//
//  Credits.swift
//  boringNotch
//
//  Credits shown in Settings → About: original authors, contributors and
//  the modifications in this fork.
//

import SwiftUI

enum Credits {
    static let modifiedBy = "abpson"
    static let modifiedByURL = URL(string: "https://github.com/abpsonx/boring.notch")!
    static let originalURL = URL(string: "https://github.com/TheBoredTeam/boring.notch")!

    /// GitHub contributors of TheBoredTeam/boring.notch, by number of contributions.
    static let contributors: [String] = [
        "Alexander5015",
        "theboringhumane",
        "richardkunkli",
        "OmChachad",
        "freepicheep",
        "AlexLemus-Dev",
        "Al3Gr",
        "mustafa-ramax",
        "weitheng01",
        "overflow-sudo",
        "AdrianGri",
        "HXavier21",
        "Decryptu",
        "Kraigo",
        "BoredDevNL",
        "CrossTR15YT",
        "Corentin132",
        "eexxio",
        "divyanshu0469",
        "Ein-Tim",
        "Sn0wBiT",
        "sakvarelidze",
        "claude",
        "ftery0",
        "wwuselessww",
        "naq7826",
        "matejzvikl23",
        "bueckerlars",
        "charshith",
        "andreamoretti890",
        "yaxarat",
        "urmit-chauhan",
        "TBGStrixzz",
        "Precontation",
        "sancho1952007",
        "Oscillix",
        "oorischubert",
        "rtpHarry",
        "M7T5M3P",
        "TheMalenia",
        "lambegraham",
        "EnesCinr",
        "Davetheword",
        "ChemicalChaos-Fabian42",
        "antonioacademy10",
        "adam-dziuk",
    ]

    /// Features added in this modified version.
    static let forkFeatures: [String] = [
        "Weather", "Clipboard & screenshot history", "Break & water reminders",
        "Notifications in the notch", "Notes with Calendar & Reminders", "Daily & extra tasks", "File converter",
        "Download progress", "Animated charging", "Rainbow visualizer", "Cache cleaner",
    ]
}

/// Credits sections for the About page.
struct CreditsSections: View {
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)]

    var body: some View {
        Section {
            HStack {
                Text("Original app")
                Spacer()
                Link("TheBoredTeam / boring.notch", destination: Credits.originalURL)
            }
            HStack {
                Text("Modified by")
                Spacer()
                Link(Credits.modifiedBy, destination: Credits.modifiedByURL)
                    .fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Added in this version")
                Text(Credits.forkFeatures.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Credits")
        } footer: {
            Text("Boring Notch is free software under the GNU GPL v3. This is a modified version of the original by TheBoredTeam.")
        }

        Section {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Credits.contributors, id: \.self) { login in
                    if let url = URL(string: "https://github.com/\(login)") {
                        Link("@\(login)", destination: url)
                            .font(.callout)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Contributors (\(Credits.contributors.count))")
        } footer: {
            Text("Plus everyone who translated Boring Notch on Crowdin. Thank you!")
        }
    }
}
