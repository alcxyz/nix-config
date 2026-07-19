pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property string mode: Quickshell.env("NIXBOX_SPLASH_MODE") || "startup"
    readonly property bool powerTransition: mode === "shutdown" || mode === "reboot"
    readonly property string subtitle: mode === "shutdown" ? "POWERING OFF" : mode === "reboot" ? "RESTARTING" : "MEDIA CENTER"
    readonly property real duration: powerTransition ? 4.1 : 4.85
    property real elapsed: 0
    property double startedAt: 0
    readonly property int settleDelayMs: {
        const configured = Number(Quickshell.env("NIXBOX_SPLASH_SETTLE_MS"));
        return Number.isFinite(configured) && configured >= 0 ? configured : 250;
    }

    function clamp(value) {
        return Math.max(0, Math.min(1, value));
    }

    function smooth(value) {
        const progress = clamp(value);
        return progress * progress * (3 - 2 * progress);
    }

    function easeOutCubic(value) {
        const progress = clamp(value);
        return 1 - Math.pow(1 - progress, 3);
    }

    function easeInCubic(value) {
        const progress = clamp(value);
        return progress * progress * progress;
    }

    function beginAnimation() {
        if (startedAt === 0)
            startedAt = Date.now();
    }

    function startupLetterOpacity(index) {
        if (index === 2 || index === 5)
            return easeOutCubic((elapsed - 0.1) / 0.5);
        const order = index === 0 ? 0 : index === 1 ? 1 : index === 3 ? 2 : 3;
        return easeOutCubic((elapsed - 2.3 - order * 0.12) / 0.7);
    }

    function powerLetterOpacity(index) {
        if (index === 2 || index === 5)
            return 1 - easeInCubic((elapsed - 3.0) / 0.6);
        const order = index === 0 ? 0 : index === 1 ? 1 : index === 3 ? 2 : 3;
        return 1 - easeInCubic((elapsed - 0.7 - order * 0.1) / 0.5);
    }

    Timer {
        interval: 16
        running: root.startedAt > 0
        repeat: true
        onTriggered: {
            root.elapsed = (Date.now() - root.startedAt) / 1000;
            if (root.elapsed >= root.duration)
                Qt.quit();
        }
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: splashWindow

            required property var modelData
            readonly property real layoutScale: Math.min(width / 1920, height / 1080)
            readonly property real startupFade: root.easeInCubic((root.elapsed - 4.2) / 0.65)

            screen: modelData
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore

            anchors {
                top: true
                right: true
                bottom: true
                left: true
            }

            WlrLayershell.namespace: "nixbox:session-splash"
            WlrLayershell.layer: WlrLayershell.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            mask: Region {
                width: 0
                height: 0
            }

            Timer {
                interval: root.settleDelayMs
                running: splashWindow.backingWindowVisible && root.startedAt === 0
                repeat: false
                onTriggered: root.beginAnimation()
            }

            Rectangle {
                anchors.fill: parent
                color: "#0b0c0f"
                opacity: root.powerTransition ? 1 : 1 - splashWindow.startupFade

                Image {
                    anchors.centerIn: parent
                    width: parent.width * 0.58
                    height: width
                    source: "nix-snowflake-white.svg"
                    fillMode: Image.PreserveAspectFit
                    opacity: root.powerTransition
                        ? 0.05 * (1 - root.easeInCubic((root.elapsed - 0.6) / 1.8))
                        : 0.05 * root.easeOutCubic((root.elapsed - 3.0) / 1.0)
                    scale: root.powerTransition ? 1 : 0.97 + 0.03 * root.easeOutCubic((root.elapsed - 3.0) / 1.0)
                    smooth: true
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 44 * splashWindow.layoutScale

                    Item {
                        id: wordmark

                        width: 624 * splashWindow.layoutScale
                        height: 106 * splashWindow.layoutScale

                        Repeater {
                            model: ["N", "I", "X", "B", "O", "X"]

                            Text {
                                required property string modelData
                                required property int index
                                readonly property real slotWidth: 104 * splashWindow.layoutScale
                                readonly property real finalX: index * slotWidth
                                readonly property real centerX: wordmark.width / 2 - slotWidth / 2
                                readonly property real travel: root.powerTransition
                                    ? root.smooth((root.elapsed - 1.7) / 1.1)
                                    : root.smooth((root.elapsed - 0.9) / 1.3)

                                x: (index === 2 || index === 5)
                                    ? (root.powerTransition
                                        ? finalX + (centerX - finalX) * travel
                                        : centerX + (finalX - centerX) * travel)
                                    : finalX
                                width: slotWidth
                                height: parent.height
                                text: modelData
                                color: "#e9edf4"
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                font.family: "Space Grotesk"
                                font.weight: Font.Light
                                font.pixelSize: 88 * splashWindow.layoutScale
                                opacity: root.powerTransition
                                    ? root.powerLetterOpacity(index)
                                    : root.startupLetterOpacity(index)
                            }
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.subtitle
                        color: "#5c6470"
                        font.family: "Space Grotesk"
                        font.weight: Font.Normal
                        font.capitalization: Font.AllUppercase
                        font.pixelSize: 24 * splashWindow.layoutScale
                        font.letterSpacing: 8.16 * splashWindow.layoutScale
                        opacity: root.powerTransition
                            ? 1 - root.easeInCubic((root.elapsed - 1.2) / 0.8)
                            : root.easeOutCubic((root.elapsed - 3.0) / 0.8)
                    }
                }
            }
        }
    }
}
