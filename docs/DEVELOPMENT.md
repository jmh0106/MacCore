# 개발 안내

MacCore는 Apple Silicon Mac을 위한 SwiftUI + AppKit 앱입니다. 사용자용 소개·설치·제한 사항은 [README](../README.md)를 참고하세요.

## 실행과 서명

`MacCore.xcodeproj`를 열고 MacCore / My Mac을 선택합니다. 기본값은 ad-hoc 서명입니다. 고정된 개발 인증서를 사용하려면 `Config/Signing.local.xcconfig`에 본인의 `CODE_SIGN_IDENTITY`와 `DEVELOPMENT_TEAM`을 지정하세요. 이 로컬 파일은 Git에서 제외됩니다. 현재 설정은 arm64, macOS 14 이상을 대상으로 하며 Xcode 27에서 검증했습니다.

```sh
xcodebuild -project MacCore.xcodeproj -scheme MacCore \
  -configuration Debug -derivedDataPath .build/DerivedData build
```

기존 실행본을 정상 종료한 뒤 새 빌드를 실행하세요. MacCore는 한 번에 한 인스턴스만 실행하며, 다른 경로의 앱을 열어도 기존 실행본이 유지될 수 있습니다. 종료 안내에 임시 캡처가 보이면 먼저 필요한 이미지를 저장하세요.

## 배포

바이너리는 소스에 커밋하지 않고 GitHub Releases에 올립니다. 기본 배포 형식은 `MacCore-버전-arm64.dmg`이며 `MacCore.app`과 `/Applications` 바로가기를 넣습니다. 빌드 결과물·DMG·개인 서명 파일은 `.gitignore`에서 제외합니다.

```sh
xcodebuild -project MacCore.xcodeproj -scheme MacCore \
  -configuration Release -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

현재 공개 배포본은 ad-hoc 서명으로, Developer ID 공증을 받은 앱이 아닙니다. 다른 Mac의 첫 실행 경고와 업데이트 후 권한 유지 여부를 별도로 확인해야 합니다. 개발 중에는 기존 로컬 서명 신원을 유지하세요.

## 코드 구성

| 위치 | 역할 |
| :--- | :--- |
| `MacCore/AppDelegate.swift` | 앱 수명, 메뉴 막대, 설정 창, 단축키 |
| `MacCore/AppModel.swift` | 공유 상태, 타이머·포모도로, 파일·클립보드 |
| `MacCore/Views.swift`, `IslandControls.swift` | 도구 패널, 작은 섬, 알림, 빠른 실행 |
| `MacCore/OverlayController.swift` | 화면 배치, 호버와 드래그 감지 |
| `MacCore/QuickControls.swift` | 스크롤 방향, F19 입력기 순환, 시스템 알림 음량 |
| `MacCore/Music.swift`, `SystemMonitor.swift` | 미디어 정보와 시스템 상태 |
| `MacCore/AIUsage.swift`, `ActivityMonitors.swift` | 구독 한도와 완료·스크린샷·알림 감지 |
| `MacCore/CoreLogic.swift` | 타이머·위치·중복 처리 등의 순수 로직 |

MediaRemoteAdapter는 리비전 `5b6afde3f501a3da567e23bf7f23d562938a1809`에 고정되어 있습니다. 의존성 라이선스는 [ThirdPartyNotices.txt](../MacCore/ThirdPartyNotices.txt)에 정리되어 있습니다.

## 검사

```sh
mkdir -p .build/checks .build/ModuleCache
xcrun swiftc -module-cache-path .build/ModuleCache \
  MacCore/CoreLogic.swift Tests/CoreLogicChecks.swift \
  -o .build/checks/core-checks
.build/checks/core-checks

xcrun swiftc -module-cache-path .build/ModuleCache \
  MacCore/QuickControls.swift Tests/QuickControlChecks.swift \
  -o .build/checks/quick-control-checks
.build/checks/quick-control-checks
```

`quick-control-checks --integration`은 실제 스크롤 방향·알림 음량·입력기·키 매핑을 잠깐 변경한 뒤 복원하는 수동 실행용 검사입니다. F19를 등록한 MacCore 실행본을 먼저 종료해야 합니다. 일반 검사에는 시스템 설정 변경이 없습니다.

추가 검사 파일은 `Tests/DesignChecks.swift`, `Tests/IslandChecks.swift`, `Tests/NowPlayingChecks.swift`입니다. SwiftUI 호스트의 콘텐츠 높이, 섬 배치, 클립보드 중복·민감 정보 정책, 미디어 상태 전환 등을 다룹니다. AppKit·SwiftUI 및 MediaRemoteAdapter가 필요한 검사는 해당 앱 소스와 패키지를 함께 링크해야 합니다.

## README 이미지

[assets](assets/)의 PNG와 GIF는 실제 앱 뷰를 데모 데이터로 렌더링한 자료입니다. 음악·앨범 이미지·파일·클립보드 항목·시스템 수치·AI 한도는 예시이며 실제 계정과 개인 파일을 사용하지 않았습니다. GIF는 같은 SwiftUI 섬 뷰의 호버·펼치기·접기·알림 화면을 연결해 만든 동작 미리보기이며, 실시간 화면 녹화는 아닙니다.

## AI 완료 신호

MacCore는 아래 로컬 디렉터리의 완료 신호를 확인합니다. 배포된 소스가 외부 도구의 후크를 자동 설치하지는 않습니다. 도구의 완료 후크에서 해당 파일을 쓰도록 연결하거나, 설정에서 macOS 완료 배너 감지를 사용하세요.

```text
~/Library/Application Support/MacCore/AI Completion Signals/
  codex           # 파일 내용: codex
  claude-code     # 파일 내용: claude-code
  antigravity     # 파일 내용: antigravity
```

UTF-8 텍스트로 공급자 이름만 기록하며 작업 내용·대화는 넣지 않습니다. MacCore는 신호를 소비한 뒤 파일을 제거합니다. 앱의 ‘AI 작업 완료’ 설정도 켜져 있어야 합니다.
