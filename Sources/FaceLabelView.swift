import SwiftUI

struct FaceLabelView: View {
    let detectedFaces: [DetectedFace]
    let photoDate: Date?
    @ObservedObject var faceManager: FaceManager
    var onFacesUpdated: ([DetectedFace]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Detected Faces")
                    .font(.headline)
                Text("(\(detectedFaces.count))")
                    .foregroundStyle(.secondary)
            }

            if detectedFaces.isEmpty {
                Text("No faces detected in this photo.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(detectedFaces) { face in
                            FaceCropCard(
                                face: face,
                                faceManager: faceManager,
                                onLabeled: { name in
                                    labelFace(face, name: name)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func labelFace(_ face: DetectedFace, name: String) {
        faceManager.labelFace(
            name: name,
            featurePrint: face.featurePrint,
            cropImage: face.cropImage,
            photoDate: photoDate
        )
        // Update the face's matched name
        var updated = detectedFaces
        if let idx = updated.firstIndex(where: { $0.id == face.id }) {
            updated[idx].matchedName = name
        }
        onFacesUpdated(updated)
    }
}

struct FaceCropCard: View {
    let face: DetectedFace
    @ObservedObject var faceManager: FaceManager
    var onLabeled: (String) -> Void

    @State private var isLabeling = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: face.cropImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(borderColor, lineWidth: 2)
                )

            if let name = face.matchedName, !isLabeling {
                // Confident match
                VStack(spacing: 4) {
                    Text(name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    if let dist = face.matchDistance {
                        Text(String(format: "%.2f", dist))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Button("Save") { onLabeled(name) }
                        Button("Change") { isLabeling = true }
                    }
                    .font(.caption2)
                }
            } else if face.isAmbiguous && !isLabeling {
                // Ambiguous match — show candidates
                VStack(spacing: 4) {
                    Text("Uncertain")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.yellow)
                    ForEach(face.ambiguousNames, id: \.self) { name in
                        Button(name) { onLabeled(name) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                    Button("Other...") { isLabeling = true }
                        .font(.caption2)
                }
            } else if isLabeling {
                // Manual labeling
                VStack(spacing: 4) {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 100)
                        .onSubmit {
                            submitLabel()
                        }

                    if !faceManager.knownNames.isEmpty {
                        Menu("Pick") {
                            ForEach(faceManager.knownNames, id: \.self) { name in
                                Button(name) {
                                    newName = name
                                    submitLabel()
                                }
                            }
                        }
                        .font(.caption)
                    }

                    HStack(spacing: 4) {
                        Button("Save") { submitLabel() }
                            .disabled(newName.isEmpty)
                        Button("Cancel") { isLabeling = false }
                    }
                    .font(.caption)
                }
            } else {
                // No match
                Button("Label") { isLabeling = true }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
    }

    private var borderColor: Color {
        if face.matchedName != nil { return .green }
        if face.isAmbiguous { return .yellow }
        return .orange
    }

    private func submitLabel() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onLabeled(name)
        isLabeling = false
        newName = ""
    }
}

// MARK: - Known Faces Management View

struct KnownFacesView: View {
    @ObservedObject var faceManager: FaceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Known Faces")
                    .font(.headline)
                Text("(\(faceManager.knownFaces.count) samples, \(faceManager.knownNames.count) people)")
                    .foregroundStyle(.secondary)
            }

            if faceManager.knownFaces.isEmpty {
                Text("No faces labeled yet. Detect faces in photos and label them to build your database.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                let grouped = Dictionary(grouping: faceManager.knownFaces, by: \.name)
                List {
                    ForEach(grouped.keys.sorted(), id: \.self) { name in
                        PersonSection(
                            name: name,
                            faces: grouped[name] ?? [],
                            faceManager: faceManager
                        )
                    }
                }
            }
        }
        .padding()
    }
}

struct PersonSection: View {
    let name: String
    let faces: [KnownFace]
    @ObservedObject var faceManager: FaceManager

    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(faces) { face in
                HStack(spacing: 12) {
                    if let image = faceManager.cropImageForKnownFace(face) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading) {
                        if let photoDate = face.photoDate {
                            Text("Photo: \(photoDate, style: .date)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Added: \(face.dateAdded, style: .date)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        faceManager.removeFace(id: face.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack(spacing: 12) {
                if let first = faces.first,
                   let image = faceManager.cropImageForKnownFace(first) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                }

                if isRenaming {
                    TextField("New name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .onSubmit { submitRename() }
                    Button("OK") { submitRename() }
                        .font(.caption)
                    Button("Cancel") {
                        isRenaming = false
                        newName = ""
                    }
                    .font(.caption)
                } else {
                    Text(name)
                        .fontWeight(.medium)
                    Text("\(faces.count) samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        newName = name
                        isRenaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        for face in faces {
                            faceManager.removeFace(id: face.id)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func submitRename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        faceManager.renamePerson(oldName: name, newName: trimmed)
        isRenaming = false
        newName = ""
    }
}
