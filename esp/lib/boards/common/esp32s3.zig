pub const wifi = struct {
    pub const static_tx_buffer_num = 24;
    pub const cache_tx_buffer_num = 32;
};

pub const lwip = struct {
    pub const tcpip_task_affinity_no_affinity = false;
    pub const tcpip_task_affinity_cpu0 = true;
    pub const tcpip_task_affinity_cpu1 = false;
};

pub const task_policy = .{
    .zux = .{
        .priority = 5,
        .core_id = 1,
    },
    .audio = .{
        .priority = 10,
        .core_id = 1,
    },
    .bt = .{
        .priority = 6,
        .core_id = 0,
    },
    .context = .{
        .priority = 5,
        .core_id = 1,
    },
    .net = .{
        .priority = 6,
        .core_id = 0,
    },
    .giznet = .{
        .priority = 6,
        .core_id = 0,
    },
    .gizclaw = .{
        .priority = 5,
        .core_id = 0,
    },
    .lvgl = .{
        .priority = 5,
        .core_id = 1,
    },
    .sync = .{
        .priority = 5,
        .core_id = 1,
    },
    .testing = .{
        .priority = 5,
    },
};
