import Config

config :nerve_center, :devices, [
  %{
    id: :hal9000,
    label: "HAL9000",
    hostname: "hal9000",
    ip: "100.116.98.76",
    display_order: 1,
    enabled: true,
    offline_expected: false,
    hub_module: NerveCenter.Devices.HAL9000Hub,
    launchd_labels: [
      "com.claudebot.title-standards",
      "com.claudebot.heartbeat",
      "com.claudebot.dashboard-v3",
      "com.claudebot.olympics-2026",
      "com.claudebot.land-scout-v3",
      "com.claudebot.basecamp",
      "com.claudebot.braindump",
      "com.claudebot.youtube-ripper",
      "com.claudebot.landscout-scrape"
    ],
    plex_base_url: "http://127.0.0.1:32400",
    sources: [
      %{
        name: :local_metrics,
        module: NerveCenter.Sources.HAL9000.LocalMetricsSource,
        enabled: true,
        interval_ms: 10_000
      },
      %{
        name: :launchd,
        module: NerveCenter.Sources.HAL9000.LaunchdSource,
        enabled: true,
        interval_ms: 15_000
      },
      %{
        name: :plex,
        module: NerveCenter.Sources.HAL9000.PlexSource,
        enabled: true,
        interval_ms: 30_000
      }
    ]
  },
  %{
    id: :kitt,
    label: "KITT",
    hostname: "kitt",
    ip: "100.97.130.40",
    display_order: 2,
    enabled: true,
    offline_expected: false,
    hub_module: NerveCenter.Devices.KittHub,
    glances_base_url: "http://100.97.130.40:61208",
    pihole_base_url: "http://100.97.130.40",
    sources: [
      %{
        name: :glances,
        module: NerveCenter.Sources.Kitt.GlancesSource,
        enabled: true,
        interval_ms: 30_000
      },
      %{
        name: :pihole,
        module: NerveCenter.Sources.Kitt.PiHoleSource,
        enabled: true,
        interval_ms: 30_000
      }
    ]
  },
  %{
    id: :ups,
    label: "UPS",
    hostname: "kitt",
    ip: "100.97.130.40",
    display_order: 3,
    enabled: true,
    offline_expected: false,
    hub_module: NerveCenter.Devices.UpsHub,
    nut_host: "100.97.130.40",
    nut_port: 3493,
    nut_device: "cyberpower",
    sources: [
      %{
        name: :nut,
        module: NerveCenter.Sources.Ups.NUTSource,
        enabled: true,
        interval_ms: 30_000
      }
    ]
  },
  %{
    id: :rosie,
    label: "ROSIE",
    hostname: "rosie",
    ip: "100.75.76.66",
    display_order: 4,
    enabled: false,
    offline_expected: false,
    hub_module: NerveCenter.Devices.RosieHub,
    glances_base_url: "http://100.75.76.66:61208",
    frigate_base_url: "http://100.75.76.66:5000",
    immich_base_url: "http://100.75.76.66:2283",
    frigate_preview_cameras: ["livingroom"],
    sources: [
      %{
        name: :glances,
        module: NerveCenter.Sources.Rosie.GlancesSource,
        enabled: false,
        interval_ms: 30_000
      },
      %{
        name: :frigate,
        module: NerveCenter.Sources.Rosie.FrigateSource,
        enabled: false,
        interval_ms: 30_000
      },
      %{
        name: :frigate_preview,
        module: NerveCenter.Sources.Rosie.FrigatePreviewSource,
        enabled: false,
        interval_ms: 10_000
      },
      %{
        name: :immich,
        module: NerveCenter.Sources.Rosie.ImmichSource,
        enabled: false,
        interval_ms: 60_000
      }
    ]
  },
  %{
    id: :daisy,
    label: "DAISY",
    hostname: "daisy",
    ip: "100.103.249.3",
    display_order: 5,
    enabled: false,
    offline_expected: false,
    hub_module: NerveCenter.Devices.DaisyHub,
    home_assistant_base_url: "http://100.103.249.3:8123",
    curated_entity_ids: [],
    sources: [
      %{
        name: :ha_web_socket,
        module: NerveCenter.Sources.Daisy.HAWebSocketSource,
        enabled: false,
        interval_ms: 90_000
      },
      %{
        name: :ha_rest_probe,
        module: NerveCenter.Sources.Daisy.HARestProbe,
        enabled: false,
        interval_ms: 300_000
      }
    ]
  },
  %{
    id: :stig,
    label: "Stig",
    hostname: "stig",
    ip: "192.168.0.1",
    display_order: 6,
    enabled: false,
    offline_expected: false,
    hub_module: NerveCenter.Devices.StigHub,
    unifi_base_url: "https://192.168.0.1",
    unifi_site_slug: "default",
    sources: [
      %{
        name: :unifi,
        module: NerveCenter.Sources.Stig.UniFiSource,
        enabled: false,
        interval_ms: 60_000
      }
    ]
  },
  %{
    id: :ubuntu_laptop,
    label: "Ubuntu Laptop",
    hostname: "zoidberg",
    ip: "100.126.22.36",
    display_order: 7,
    enabled: false,
    offline_expected: true,
    hub_module: NerveCenter.Devices.UbuntuLaptopHub,
    glances_base_url: "http://100.126.22.36:61208",
    sources: [
      %{
        name: :glances,
        module: NerveCenter.Sources.UbuntuLaptop.GlancesSource,
        enabled: false,
        interval_ms: 30_000
      }
    ]
  }
]
