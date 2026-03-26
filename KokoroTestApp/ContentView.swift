import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: TestAppModel
    @State private var inputText: String = ""

    var body: some View {
        Group {
            switch viewModel.loadingState {
            case .notStarted, .loadingModel:
                VStack(spacing: 16) {
                    ProgressView()
                    Text(viewModel.loadingState == .notStarted ? "Starting..." : "Loading model...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)

            case .downloading(let progress):
                VStack(spacing: 16) {
                    ProgressView(value: progress) {
                        Text("Downloading model...")
                    } currentValueLabel: {
                        Text("\(Int(progress * 100))%")
                    }
                    .padding(.horizontal, 40)
                    Text("~600 MB \u{2014} first launch only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)

            case .error(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Failed to load model")
                        .font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") {
                        Task { await viewModel.downloadAndLoadModel() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.white)

            case .ready:
                mainView
            }
        }
    }

    private var mainView: some View {
        VStack {
            Spacer()

            TextField("Type something to say...", text: $inputText)
                .padding()
                .background(Color(.systemGray))
                .cornerRadius(8)
                .padding(.horizontal)

            Picker("Selected Voice: ", selection: $viewModel.selectedVoice) {
                ForEach(viewModel.voiceNames, id: \.self) { voice in
                    Text(voice)
                        .foregroundStyle(Color.black)
                        .tag(voice)
                }
            }
            .accentColor(.black)
            .foregroundColor(.black)
            .pickerStyle(.menu)
            .padding(.horizontal)
            .tint(.accentColor)
            .background(.gray)

            Button {
                if !inputText.isEmpty {
                    viewModel.say(inputText)
                } else {
                    viewModel.say("Please type something first")
                }
            } label: {
                HStack(alignment: .center) {
                    Spacer()
                    Text("Say something")
                        .foregroundColor(.white)
                        .frame(height: 50)
                    Spacer()
                }
                .background(.black)
                .padding(.horizontal)
            }

            Text("Spoken string: " + viewModel.stringToFollowTheAudio)
                .padding()
                .foregroundStyle(.black)
                .background(.white)

            Spacer()
        }
        .background(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
