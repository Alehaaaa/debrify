#include "media_session_win.h"

#include <flutter/standard_method_codec.h>
#include <unknwn.h>
#include <shcore.h>
#include <shlwapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>
#include <deque>
#include <optional>
#include <string>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
namespace wm = winrt::Windows::Media;
namespace wss = winrt::Windows::Storage::Streams;

const EncodableValue* Find(const EncodableMap& args, const char* key) {
  auto found = args.find(EncodableValue(key));
  return found == args.end() ? nullptr : &found->second;
}

std::optional<int64_t> IntArg(const EncodableMap& args, const char* key) {
  const auto* value = Find(args, key);
  if (!value) return std::nullopt;
  if (const auto* v = std::get_if<int32_t>(value)) return *v;
  if (const auto* v = std::get_if<int64_t>(value)) return *v;
  return std::nullopt;
}

std::optional<bool> BoolArg(const EncodableMap& args, const char* key) {
  const auto* value = Find(args, key);
  if (!value) return std::nullopt;
  if (const auto* v = std::get_if<bool>(value)) return *v;
  return std::nullopt;
}

winrt::hstring Wide(const std::string& utf8) { return winrt::to_hstring(utf8); }

wss::IRandomAccessStream StreamFromBytes(const std::vector<uint8_t>& bytes) {
  // Synchronous on purpose: StoreAsync().get() is not allowed on this STA
  // thread, while a COM memory stream wrapped as a WinRT stream needs no wait.
  winrt::com_ptr<IStream> stream;
  stream.attach(SHCreateMemStream(bytes.data(), static_cast<UINT>(bytes.size())));
  if (!stream) return nullptr;
  wss::IRandomAccessStream result{nullptr};
  if (FAILED(CreateRandomAccessStreamOverStream(
          stream.get(), BSOS_DEFAULT,
          reinterpret_cast<IID const&>(winrt::guid_of<wss::IRandomAccessStream>()),
          winrt::put_abi(result)))) {
    return nullptr;
  }
  return result;
}

}  // namespace

struct MediaSessionWin::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  wm::SystemMediaTransportControls smtc{nullptr};
  winrt::event_token button_token{};
  winrt::event_token position_token{};
  std::mutex mutex;
  std::deque<EncodableMap> pending;

  std::string title;
  std::string subtitle;
  int64_t duration_ms = 0;
  int64_t position_ms = 0;
  bool playing = false;

  void Queue(EncodableMap command) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      pending.push_back(std::move(command));
    }
    PostMessage(window, MediaSessionWin::kCommandMessage, 0, 0);
  }

  bool Ensure() {
    if (smtc) return true;
    try {
      auto interop = winrt::get_activation_factory<
          wm::SystemMediaTransportControls,
          ISystemMediaTransportControlsInterop>();
      wm::SystemMediaTransportControls controls{nullptr};
      winrt::check_hresult(interop->GetForWindow(
          window,
          reinterpret_cast<IID const&>(
              winrt::guid_of<wm::SystemMediaTransportControls>()),
          winrt::put_abi(controls)));
      smtc = controls;
      smtc.IsPlayEnabled(true);
      smtc.IsPauseEnabled(true);
      smtc.IsStopEnabled(true);
      smtc.IsFastForwardEnabled(true);
      smtc.IsRewindEnabled(true);
      button_token = smtc.ButtonPressed(
          [this](auto const&,
                 wm::SystemMediaTransportControlsButtonPressedEventArgs const&
                     args) {
            std::string action;
            int64_t offset = 0;
            switch (args.Button()) {
              case wm::SystemMediaTransportControlsButton::Play:
                action = "play";
                break;
              case wm::SystemMediaTransportControlsButton::Pause:
              case wm::SystemMediaTransportControlsButton::Stop:
                action = "pause";
                break;
              case wm::SystemMediaTransportControlsButton::Next:
                action = "next";
                break;
              case wm::SystemMediaTransportControlsButton::Previous:
                action = "previous";
                break;
              case wm::SystemMediaTransportControlsButton::FastForward:
                action = "seekBy";
                offset = 10000;
                break;
              case wm::SystemMediaTransportControlsButton::Rewind:
                action = "seekBy";
                offset = -10000;
                break;
              default:
                return;
            }
            EncodableMap command{{EncodableValue("action"), EncodableValue(action)}};
            if (offset != 0) {
              command[EncodableValue("offsetMs")] = EncodableValue(offset);
            }
            Queue(std::move(command));
          });
      position_token = smtc.PlaybackPositionChangeRequested(
          [this](auto const&,
                 wm::PlaybackPositionChangeRequestedEventArgs const& args) {
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                args.RequestedPlaybackPosition())
                                .count();
            Queue(EncodableMap{
                {EncodableValue("action"), EncodableValue("seek")},
                {EncodableValue("positionMs"), EncodableValue(static_cast<int64_t>(ms))},
            });
          });
      return true;
    } catch (...) {
      smtc = nullptr;
      return false;
    }
  }

  void Update(const EncodableMap& args) {
    if (!Ensure()) return;
    try {
      bool metadata_changed = false;
      if (const auto* v = Find(args, "title")) {
        if (const auto* s = std::get_if<std::string>(v)) {
          metadata_changed |= *s != title;
          title = *s;
        }
      }
      if (const auto* v = Find(args, "subtitle")) {
        const auto* s = std::get_if<std::string>(v);
        const std::string next = s ? *s : std::string();
        metadata_changed |= next != subtitle;
        subtitle = next;
      }
      if (auto v = IntArg(args, "durationMs")) duration_ms = *v;
      if (auto v = IntArg(args, "positionMs")) position_ms = *v;
      if (auto v = BoolArg(args, "playing")) playing = *v;
      if (auto v = BoolArg(args, "canNext")) smtc.IsNextEnabled(*v);
      if (auto v = BoolArg(args, "canPrevious")) smtc.IsPreviousEnabled(*v);

      auto updater = smtc.DisplayUpdater();
      const auto* artwork = Find(args, "artwork");
      const auto* bytes =
          artwork ? std::get_if<std::vector<uint8_t>>(artwork) : nullptr;
      const bool clear_artwork = BoolArg(args, "clearArtwork").value_or(false);
      if (metadata_changed || bytes || clear_artwork) {
        updater.Type(wm::MediaPlaybackType::Video);
        updater.VideoProperties().Title(Wide(title));
        updater.VideoProperties().Subtitle(Wide(subtitle));
        if (bytes && !bytes->empty()) {
          if (auto stream = StreamFromBytes(*bytes)) {
            updater.Thumbnail(wss::RandomAccessStreamReference::CreateFromStream(stream));
          }
        } else if (clear_artwork) {
          updater.Thumbnail(nullptr);
        }
        updater.Update();
      }

      smtc.PlaybackStatus(playing ? wm::MediaPlaybackStatus::Playing
                                  : wm::MediaPlaybackStatus::Paused);
      wm::SystemMediaTransportControlsTimelineProperties timeline;
      const auto end = std::chrono::milliseconds(duration_ms);
      timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
      timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
      timeline.EndTime(end);
      timeline.MaxSeekTime(end);
      timeline.Position(std::chrono::milliseconds(position_ms));
      smtc.UpdateTimelineProperties(timeline);
      smtc.IsEnabled(true);
    } catch (...) {
      // A broken overlay must never take playback down with it.
    }
  }

  void Clear() {
    if (!smtc) return;
    try {
      smtc.PlaybackStatus(wm::MediaPlaybackStatus::Closed);
      smtc.DisplayUpdater().ClearAll();
      smtc.IsEnabled(false);
    } catch (...) {
    }
    title.clear();
    subtitle.clear();
    duration_ms = 0;
    position_ms = 0;
    playing = false;
  }
};

MediaSessionWin::MediaSessionWin(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>()) {
  impl_->window = window;
  impl_->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "debrify/media_session",
      &flutter::StandardMethodCodec::GetInstance());
  impl_->channel->SetMethodCallHandler(
      [impl = impl_.get()](
          const flutter::MethodCall<EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "update") {
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            impl->Update(*args);
          }
          result->Success();
        } else if (call.method_name() == "clear") {
          impl->Clear();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

MediaSessionWin::~MediaSessionWin() {
  impl_->channel->SetMethodCallHandler(nullptr);
  if (impl_->smtc) {
    try {
      impl_->smtc.ButtonPressed(impl_->button_token);
      impl_->smtc.PlaybackPositionChangeRequested(impl_->position_token);
    } catch (...) {
    }
    impl_->Clear();
  }
}

void MediaSessionWin::FlushCommands() {
  std::deque<EncodableMap> commands;
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    commands.swap(impl_->pending);
  }
  for (auto& command : commands) {
    impl_->channel->InvokeMethod(
        "command", std::make_unique<EncodableValue>(std::move(command)));
  }
}
