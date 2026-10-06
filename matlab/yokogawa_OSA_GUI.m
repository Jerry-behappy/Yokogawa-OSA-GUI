function yokogawa_OSA_GUI
% YOKOGAWA_OSA_GUI Yokogawa AQ6370D 光谱仪以太网控制界面。
% By ZJY, JNU-MWP
% 使用方法：
%   1. 光谱仪 SYSTEM -> Remote Interface 选择 Net(Socket)。
%   2. 在 MATLAB 中运行 yokogawa_OSA_GUI。
%   3. 确认 IP 和端口后连接，设置扫描参数并采集。
%
% GUI 支持单次/连续采集、TRA/TRB/TRC 配置、A-B(LOG) 数学 Trace，
% 以及带时间戳的 MAT + CSV 数据保存。

    preference_group = 'YokogawaOSAGUI';
    script_folder = fileparts(mfilename('fullpath'));
    settings = loadSettings(preference_group, script_folder);

    osa = [];
    is_connected = false;
    is_acquiring = false;
    is_continuous = false;
    is_closing = false;
    stop_requested = false;
    cycle_ready_for_restart = false;
    acquisition_phase = 'idle';
    acquisition_context = '';
    pending_traces = {};
    opc_wait_clock = [];
    acquisition_timer = [];
    plot_lines = gobjects(1, 3);
    latest_data = [];
    instrument_id = '';
    completed_acquisition_count = 0;

    %% 主界面
    fig = uifigure( ...
        'Name', 'Yokogawa OSA 远程控制', ...
        'Position', settings.windowPosition, ...
        'Color', [0.96, 0.97, 0.98], ...
        'AutoResizeChildren', 'off', ...
        'CloseRequestFcn', @closeGUI);
    setappdata(fig, 'CompletedAcquisitions', 0);
    setappdata(fig, 'AcquisitionStartedAt', NaT);
    setappdata(fig, 'AcquisitionCompletedAt', NaT);

    main_grid = uigridlayout(fig, [4, 1]);
    main_grid.RowHeight = {32, 112, '1x', 30};
    main_grid.ColumnWidth = {'1x'};
    main_grid.Padding = [10, 10, 10, 10];
    main_grid.RowSpacing = 8;

    signature_label = uilabel(main_grid, ...
        'Text', 'By Junyi Zhang, JNU MWP | 2026-07-05', ...
        'HorizontalAlignment', 'right', ...
        'FontSize', 16, ...
        'FontWeight', 'bold', ...
        'FontColor', [0.30, 0.34, 0.38]);
    signature_label.Layout.Row = 1;

    %% 连接区域
    connection_panel = uipanel(main_grid, ...
        'Title', '以太网连接', ...
        'FontWeight', 'bold');
    connection_panel.Layout.Row = 2;

    connection_grid = uigridlayout(connection_panel, [2, 10]);
    connection_grid.RowHeight = {32, 30};
    connection_grid.ColumnWidth = {34, 128, 42, 76, 50, 70, 26, 72, '1x', 88};
    connection_grid.Padding = [8, 6, 8, 6];
    connection_grid.ColumnSpacing = 6;

    addLabel(connection_grid, 'IP：', 1, 1);
    ip_field = uieditfield(connection_grid, 'text', ...
        'Value', settings.ipAddress, ...
        'ValueChangedFcn', @persistentSettingChanged);
    ip_field.Layout.Row = 1;
    ip_field.Layout.Column = 2;

    addLabel(connection_grid, '端口：', 1, 3);
    port_spinner = uispinner(connection_grid, ...
        'Limits', [1, 65535], ...
        'RoundFractionalValues', 'on', ...
        'ValueDisplayFormat', '%d', ...
        'Value', settings.port, ...
        'ValueChangedFcn', @persistentSettingChanged);
    port_spinner.Layout.Row = 1;
    port_spinner.Layout.Column = 4;

    addLabel(connection_grid, '超时(s)：', 1, 5);
    timeout_spinner = uispinner(connection_grid, ...
        'Limits', [1, 120], ...
        'RoundFractionalValues', 'on', ...
        'Value', settings.timeout, ...
        'ValueChangedFcn', @persistentSettingChanged);
    timeout_spinner.Layout.Row = 1;
    timeout_spinner.Layout.Column = 6;

    connection_lamp = uilamp(connection_grid, 'Color', [0.75, 0.20, 0.20]);
    connection_lamp.Layout.Row = 1;
    connection_lamp.Layout.Column = 7;

    connection_text = uilabel(connection_grid, ...
        'Text', '未连接', ...
        'FontWeight', 'bold');
    connection_text.Layout.Row = 1;
    connection_text.Layout.Column = 8;

    connect_button = uibutton(connection_grid, 'push', ...
        'Text', '连接', ...
        'FontWeight', 'bold', ...
        'BackgroundColor', [0.16, 0.45, 0.72], ...
        'FontColor', [1, 1, 1], ...
        'ButtonPushedFcn', @toggleConnection);
    connect_button.Layout.Row = 1;
    connect_button.Layout.Column = 9;

    addLabel(connection_grid, '仪器：', 2, 1);
    idn_field = uieditfield(connection_grid, 'text', ...
        'Value', '尚未连接仪器', ...
        'Editable', 'off');
    idn_field.Layout.Row = 2;
    idn_field.Layout.Column = [2, 10];

    %% 主工作区
    content_grid = uigridlayout(main_grid, [1, 2]);
    content_grid.Layout.Row = 3;
    content_grid.ColumnWidth = {390, '1x'};
    content_grid.RowHeight = {'1x'};
    content_grid.Padding = [0, 0, 0, 0];
    content_grid.ColumnSpacing = 8;

    controls_grid = uigridlayout(content_grid, [3, 1]);
    controls_grid.RowHeight = {235, 250, '1x'};
    controls_grid.ColumnWidth = {'1x'};
    controls_grid.Padding = [0, 0, 0, 0];
    controls_grid.RowSpacing = 8;

    %% 扫描与采集设置
    scan_panel = uipanel(controls_grid, ...
        'Title', '扫描与采集', ...
        'FontWeight', 'bold');
    scan_panel.Layout.Row = 1;
    scan_grid = uigridlayout(scan_panel, [6, 4]);
    scan_grid.RowHeight = {30, 30, 30, 30, 34, 30};
    scan_grid.ColumnWidth = {90, '1x', 90, '1x'};
    scan_grid.Padding = [8, 6, 8, 6];
    scan_grid.RowSpacing = 4;
    scan_grid.ColumnSpacing = 6;

    addLabel(scan_grid, '中心波长 (nm)', 1, 1);
    center_spinner = uispinner(scan_grid, ...
        'Limits', [600, 2400], ...
        'Step', 1, ...
        'Value', settings.centerNm, ...
        'ValueChangedFcn', @scanSettingChanged);
    center_spinner.Layout.Row = 1;
    center_spinner.Layout.Column = 2;

    addLabel(scan_grid, '跨度 (nm)', 1, 3);
    span_spinner = uispinner(scan_grid, ...
        'Limits', [0.01, 2000], ...
        'Step', 1, ...
        'Value', settings.spanNm, ...
        'ValueChangedFcn', @scanSettingChanged);
    span_spinner.Layout.Row = 1;
    span_spinner.Layout.Column = 4;

    addLabel(scan_grid, '分辨率', 2, 1);
    rbw_dropdown = uidropdown(scan_grid, ...
        'Items', {'0.02 nm', '0.05 nm', '0.1 nm', '0.2 nm', '0.5 nm', '1 nm', '2 nm'}, ...
        'Value', settings.rbwNm, ...
        'ValueChangedFcn', @rbwSettingChanged);
    rbw_dropdown.Layout.Row = 2;
    rbw_dropdown.Layout.Column = 2;

    addLabel(scan_grid, '灵敏度模式', 2, 3);
    sensitivity_dropdown = uidropdown(scan_grid, ...
        'Items', {'NORMAL', 'MID', 'HIGH1', 'HIGH2'}, ...
        'Value', settings.sensitivityMode, ...
        'ValueChangedFcn', @sensitivitySettingChanged);
    sensitivity_dropdown.Layout.Row = 2;
    sensitivity_dropdown.Layout.Column = 4;

    addLabel(scan_grid, '点数', 3, 1);
    points_dropdown = uidropdown(scan_grid, ...
        'Items', {'Auto', '101', '201', '501', '1001', '2001', ...
            '5001', '10001', '20001', '50001'}, ...
        'Value', settings.samplePoints, ...
        'ValueChangedFcn', @samplePointsChanged);
    points_dropdown.Layout.Row = 3;
    points_dropdown.Layout.Column = 2;

    points_status = uilabel(scan_grid, ...
        'Text', '作图点数：尚无数据', ...
        'FontColor', [0.35, 0.35, 0.35], ...
        'HorizontalAlignment', 'left');
    points_status.Layout.Row = 3;
    points_status.Layout.Column = [3, 4];

    single_button = uibutton(scan_grid, 'push', ...
        'Text', '单次采集', ...
        'Enable', 'off', ...
        'FontWeight', 'bold', ...
        'ButtonPushedFcn', @singleAcquisition);
    single_button.Layout.Row = 4;
    single_button.Layout.Column = [1, 4];

    start_button = uibutton(scan_grid, 'push', ...
        'Text', '开始连续采集', ...
        'Enable', 'off', ...
        'BackgroundColor', [0.16, 0.55, 0.32], ...
        'FontColor', [1, 1, 1], ...
        'ButtonPushedFcn', @startContinuousAcquisition);
    start_button.Layout.Row = 5;
    start_button.Layout.Column = [1, 2];

    stop_button = uibutton(scan_grid, 'push', ...
        'Text', '停止连续采集', ...
        'Enable', 'off', ...
        'ButtonPushedFcn', @requestContinuousStop);
    stop_button.Layout.Row = 5;
    stop_button.Layout.Column = [3, 4];

    acquisition_info = uilabel(scan_grid, ...
        'Text', '等待采集', ...
        'FontColor', [0.35, 0.35, 0.35], ...
        'HorizontalAlignment', 'center');
    acquisition_info.Layout.Row = 6;
    acquisition_info.Layout.Column = [1, 4];

    %% Trace 配置
    trace_panel = uipanel(controls_grid, ...
        'Title', 'Trace 配置', ...
        'FontWeight', 'bold');
    trace_panel.Layout.Row = 2;
    trace_grid = uigridlayout(trace_panel, [5, 4]);
    trace_grid.RowHeight = {30, 30, 30, 30, 30};
    trace_grid.ColumnWidth = {90, '1x', 90, '1x'};
    trace_grid.Padding = [8, 6, 8, 6];
    trace_grid.RowSpacing = 4;
    trace_grid.ColumnSpacing = 6;

    trace_a_checkbox = uicheckbox(trace_grid, ...
        'Text', '显示 TRA', ...
        'Value', settings.traceAOn, ...
        'ValueChangedFcn', @traceSettingChanged);
    trace_a_checkbox.Layout.Row = 1;
    trace_a_checkbox.Layout.Column = [1, 2];

    trace_b_checkbox = uicheckbox(trace_grid, ...
        'Text', '显示 TRB', ...
        'Value', settings.traceBOn, ...
        'ValueChangedFcn', @traceSettingChanged);
    trace_b_checkbox.Layout.Row = 1;
    trace_b_checkbox.Layout.Column = [3, 4];

    trace_c_checkbox = uicheckbox(trace_grid, ...
        'Text', '显示 TRC', ...
        'Value', settings.traceCOn, ...
        'ValueChangedFcn', @traceSettingChanged);
    trace_c_checkbox.Layout.Row = 2;
    trace_c_checkbox.Layout.Column = [1, 2];

    math_checkbox = uicheckbox(trace_grid, ...
        'Text', 'TRC = TRA - TRB (LOG)', ...
        'Value', settings.mathEnabled, ...
        'ValueChangedFcn', @traceSettingChanged);
    math_checkbox.Layout.Row = 2;
    math_checkbox.Layout.Column = [3, 4];

    addLabel(trace_grid, 'TRA 属性', 3, 1);
    trace_a_attr_dropdown = uidropdown(trace_grid, ...
        'Items', {'WRITE', 'FIX'}, ...
        'Value', settings.traceAAttr, ...
        'ValueChangedFcn', @traceAttributeChanged);
    trace_a_attr_dropdown.Layout.Row = 3;
    trace_a_attr_dropdown.Layout.Column = 2;

    addLabel(trace_grid, 'TRB 属性', 3, 3);
    trace_b_attr_dropdown = uidropdown(trace_grid, ...
        'Items', {'WRITE', 'FIX'}, ...
        'Value', settings.traceBAttr, ...
        'ValueChangedFcn', @traceAttributeChanged);
    trace_b_attr_dropdown.Layout.Row = 3;
    trace_b_attr_dropdown.Layout.Column = 4;

    addLabel(trace_grid, 'TRC 属性', 4, 1);
    trace_c_attr_dropdown = uidropdown(trace_grid, ...
        'Items', {'WRITE', 'FIX'}, ...
        'Value', settings.traceCAttr, ...
        'ValueChangedFcn', @traceAttributeChanged);
    trace_c_attr_dropdown.Layout.Row = 4;
    trace_c_attr_dropdown.Layout.Column = 2;

    trace_hint = uilabel(trace_grid, ...
        'Text', '修改即自动下发；TRA/TRB: dBm，数学 TRC: Loss (dB)', ...
        'FontColor', [0.35, 0.35, 0.35], ...
        'HorizontalAlignment', 'center', ...
        'WordWrap', 'on');
    trace_hint.Layout.Row = 5;
    trace_hint.Layout.Column = [1, 4];

    %% 保存设置
    save_panel = uipanel(controls_grid, ...
        'Title', '保存当前采集', ...
        'FontWeight', 'bold');
    save_panel.Layout.Row = 3;
    save_grid = uigridlayout(save_panel, [7, 4]);
    save_grid.RowHeight = {30, 30, 30, 30, 30, 34, 30};
    save_grid.ColumnWidth = {72, '1x', 64, 82};
    save_grid.Padding = [8, 6, 8, 6];
    save_grid.RowSpacing = 4;
    save_grid.ColumnSpacing = 6;

    addLabel(save_grid, '保存目录', 1, 1);
    output_folder_field = uieditfield(save_grid, 'text', ...
        'Value', settings.outputFolder, ...
        'ValueChangedFcn', @persistentSettingChanged);
    output_folder_field.Layout.Row = 1;
    output_folder_field.Layout.Column = [2, 3];

    browse_button = uibutton(save_grid, 'push', ...
        'Text', '选择...', ...
        'ButtonPushedFcn', @chooseOutputFolder);
    browse_button.Layout.Row = 1;
    browse_button.Layout.Column = 4;

    addLabel(save_grid, '基础名称', 2, 1);
    base_name_field = uieditfield(save_grid, 'text', ...
        'Value', settings.baseName, ...
        'ValueChangedFcn', @persistentSettingChanged);
    base_name_field.Layout.Row = 2;
    base_name_field.Layout.Column = [2, 4];

    addLabel(save_grid, 'Trace', 3, 1);
    save_tra_checkbox = uicheckbox(save_grid, ...
        'Text', 'TRA', ...
        'Value', settings.saveTra, ...
        'Enable', 'off', ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_tra_checkbox.Layout.Row = 3;
    save_tra_checkbox.Layout.Column = 2;

    save_trb_checkbox = uicheckbox(save_grid, ...
        'Text', 'TRB', ...
        'Value', settings.saveTrb, ...
        'Enable', 'off', ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_trb_checkbox.Layout.Row = 3;
    save_trb_checkbox.Layout.Column = 3;

    save_trc_checkbox = uicheckbox(save_grid, ...
        'Text', 'TRC', ...
        'Value', settings.saveTrc, ...
        'Enable', 'off', ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_trc_checkbox.Layout.Row = 3;
    save_trc_checkbox.Layout.Column = 4;

    addLabel(save_grid, '格式', 4, 1);
    save_mat_checkbox = uicheckbox(save_grid, ...
        'Text', 'MAT', ...
        'Value', settings.saveMat, ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_mat_checkbox.Layout.Row = 4;
    save_mat_checkbox.Layout.Column = 2;

    save_csv_checkbox = uicheckbox(save_grid, ...
        'Text', 'CSV', ...
        'Value', settings.saveCsv, ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_csv_checkbox.Layout.Row = 4;
    save_csv_checkbox.Layout.Column = 3;

    addLabel(save_grid, '元数据', 5, 1);
    save_rbw_checkbox = uicheckbox(save_grid, ...
        'Text', 'Res', ...
        'Value', settings.saveRbw, ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_rbw_checkbox.Layout.Row = 5;
    save_rbw_checkbox.Layout.Column = 2;

    save_sens_checkbox = uicheckbox(save_grid, ...
        'Text', 'SENS', ...
        'Value', settings.saveSens, ...
        'ValueChangedFcn', @persistentSettingChanged);
    save_sens_checkbox.Layout.Row = 5;
    save_sens_checkbox.Layout.Column = 3;

    save_button = uibutton(save_grid, 'push', ...
        'Text', '保存', ...
        'Enable', 'off', ...
        'FontWeight', 'bold', ...
        'ButtonPushedFcn', @saveCurrentData);
    save_button.Layout.Row = 6;
    save_button.Layout.Column = [1, 4];

    save_hint = uilabel(save_grid, ...
        'Text', '文件名 = 基础名称_Trace；重名自动追加 _1, _2...', ...
        'FontColor', [0.35, 0.35, 0.35], ...
        'WordWrap', 'on');
    save_hint.Layout.Row = 7;
    save_hint.Layout.Column = [1, 4];

    %% 绘图区
    plot_grid = uigridlayout(content_grid, [3, 1]);
    plot_grid.RowHeight = {32, '1x', 42};
    plot_grid.ColumnWidth = {'1x'};
    plot_grid.Padding = [0, 0, 0, 0];
    plot_grid.RowSpacing = 5;

    plot_info = uilabel(plot_grid, ...
        'Text', '尚无采集数据', ...
        'HorizontalAlignment', 'center', ...
        'FontSize', 14, ...
        'FontWeight', 'bold');
    plot_info.Layout.Row = 1;

    trace_names = {'TRA', 'TRB', 'TRC'};
    trace_tabs = gobjects(1, 3);
    axes_handles = gobjects(1, 3);
    plot_tabs = uitabgroup(plot_grid);
    plot_tabs.Layout.Row = 2;
    for plot_index = 1:3
        trace_tabs(plot_index) = uitab(plot_tabs, 'Title', trace_names{plot_index});
        tab_grid = uigridlayout(trace_tabs(plot_index), [1, 1]);
        tab_grid.Padding = [0, 0, 0, 0];
        axes_handles(plot_index) = uiaxes(tab_grid);
        axes_handles(plot_index).Layout.Row = 1;
        axes_handles(plot_index).Box = 'on';
        axes_handles(plot_index).XGrid = 'on';
        axes_handles(plot_index).YGrid = 'on';
        axes_handles(plot_index).FontSize = 15;
        xlabel(axes_handles(plot_index), 'Wavelength (nm)', ...
            'FontWeight', 'bold', 'FontSize', 15);
        ylabel(axes_handles(plot_index), 'Power (dBm)', ...
            'FontWeight', 'bold', 'FontSize', 15);
        title(axes_handles(plot_index), [trace_names{plot_index} ' - 未采集'], ...
            'Interpreter', 'none', 'FontSize', 16);
        plot_lines(plot_index) = plot(axes_handles(plot_index), NaN, NaN, ...
            'LineWidth', 1.2, 'Color', traceColor(trace_names{plot_index}));
    end

    axis_limit_grid = uigridlayout(plot_grid, [1, 10]);
    axis_limit_grid.Layout.Row = 3;
    axis_limit_grid.RowHeight = {32};
    axis_limit_grid.ColumnWidth = {72, 26, '1x', 18, '1x', ...
        72, 26, '1x', 18, '1x'};
    axis_limit_grid.Padding = [4, 4, 4, 4];
    axis_limit_grid.ColumnSpacing = 5;

    x_limit_auto = uicheckbox(axis_limit_grid, ...
        'Text', 'X 自动', ...
        'Value', settings.xLimitAuto, ...
        'ValueChangedFcn', @axisLimitsChanged);
    x_limit_auto.Layout.Column = 1;
    addLabel(axis_limit_grid, 'Min', 1, 2);
    x_limit_min = uieditfield(axis_limit_grid, 'numeric', ...
        'Value', settings.xLimitMin, ...
        'ValueChangedFcn', @axisLimitsChanged);
    x_limit_min.Layout.Column = 3;
    addLabel(axis_limit_grid, '至', 1, 4);
    x_limit_max = uieditfield(axis_limit_grid, 'numeric', ...
        'Value', settings.xLimitMax, ...
        'ValueChangedFcn', @axisLimitsChanged);
    x_limit_max.Layout.Column = 5;

    y_limit_auto = uicheckbox(axis_limit_grid, ...
        'Text', 'Y 自动', ...
        'Value', settings.yLimitAuto, ...
        'ValueChangedFcn', @axisLimitsChanged);
    y_limit_auto.Layout.Column = 6;
    addLabel(axis_limit_grid, 'Min', 1, 7);
    y_limit_min = uieditfield(axis_limit_grid, 'numeric', ...
        'Value', settings.yLimitMin, ...
        'ValueChangedFcn', @axisLimitsChanged);
    y_limit_min.Layout.Column = 8;
    addLabel(axis_limit_grid, '至', 1, 9);
    y_limit_max = uieditfield(axis_limit_grid, 'numeric', ...
        'Value', settings.yLimitMax, ...
        'ValueChangedFcn', @axisLimitsChanged);
    y_limit_max.Layout.Column = 10;

    %% 状态栏
    status_label = uilabel(main_grid, ...
        'Text', '就绪：请连接光谱仪', ...
        'FontColor', [0.25, 0.25, 0.25]);
    status_label.Layout.Row = 4;

    updateYAxisLabels();
    updateAxisLimitControls();
    applyAxisLimits();
    updateControlStates();
    fig.SizeChangedFcn = @saveWindowPosition;

    %% 连接回调
    function toggleConnection(~, ~)
        if is_connected
            disconnectInstrument('已断开连接');
            return;
        end

        setStatus('正在连接光谱仪...', 'info');
        connect_button.Enable = 'off';
        drawnow;
        try
            ip_address = strtrim(ip_field.Value);
            if isempty(ip_address)
                error('IP 地址不能为空。');
            end

            osa = tcpclient(ip_address, port_spinner.Value, ...
                'Timeout', timeout_spinner.Value);
            configureTerminator(osa, "CR/LF");

            authentication_response = strtrim(writeread(osa, 'open "anonymous"'));
            if ~contains(authentication_response, 'AUTHENTICATE', 'IgnoreCase', true) && ...
                    ~contains(authentication_response, 'ready', 'IgnoreCase', true)
                error('仪器未返回认证提示：%s', authentication_response);
            end

            if ~contains(authentication_response, 'ready', 'IgnoreCase', true)
                ready_response = strtrim(writeread(osa, char(13)));
                if ~contains(ready_response, 'ready', 'IgnoreCase', true)
                    error('空密码认证失败：%s', ready_response);
                end
            end

            instrument_id = strtrim(writeread(osa, '*IDN?'));
            if isempty(instrument_id)
                error('仪器未返回 *IDN? 信息。');
            end

            is_connected = true;
            connection_lamp.Color = [0.18, 0.65, 0.28];
            connection_text.Text = '已连接';
            connect_button.Text = '断开';
            connect_button.BackgroundColor = [0.70, 0.24, 0.24];
            idn_field.Value = instrument_id;
            persistentSettingChanged();
            updateControlStates();
            setStatus(['连接成功：' instrument_id], 'success');
        catch exception
            osa = [];
            is_connected = false;
            updateControlStates();
            setStatus(['连接失败：' exception.message], 'error');
        end
    end

    function disconnectInstrument(message)
        cancelContinuousAcquisition();
        is_acquiring = false;
        osa = [];
        is_connected = false;
        connection_lamp.Color = [0.75, 0.20, 0.20];
        connection_text.Text = '未连接';
        connect_button.Text = '连接';
        connect_button.BackgroundColor = [0.16, 0.45, 0.72];
        idn_field.Value = '尚未连接仪器';
        updateControlStates();
        if nargin > 0 && ~isempty(message)
            setStatus(message, 'info');
        end
    end

    %% 仪器设置（自动下发）
    function scanSettingChanged(~, ~)
        persistentSettingChanged();
        if ~is_connected || isempty(osa), return; end
        try
            center_m = center_spinner.Value * 1e-9;
            span_m = span_spinner.Value * 1e-9;
            writeline(osa, sprintf(':SENS:WAV:CENT %.12g', center_m));
            writeline(osa, sprintf(':SENS:WAV:SPAN %.12g', span_m));
        catch
        end
    end

    function rbwSettingChanged(~, ~)
        persistentSettingChanged();
        if ~is_connected || isempty(osa), return; end
        try
            rbw_nm = sscanf(rbw_dropdown.Value, '%f');
            writeline(osa, sprintf(':SENS:BANDWIDTH %.3g', rbw_nm * 1e-9));
        catch
        end
    end

    function sensitivitySettingChanged(~, ~)
        persistentSettingChanged();
        if ~is_connected || isempty(osa), return; end
        try
            mode_map = containers.Map({'NORMAL','MID','HIGH1','HIGH2'}, {6, 2, 3, 4});
            code = mode_map(sensitivity_dropdown.Value);
            writeline(osa, sprintf(':SENS:SENS %d', code));
        catch
        end
    end

    function samplePointsChanged(~, ~)
        persistentSettingChanged();
        if ~is_connected || isempty(osa), return; end
        try
            sendSamplePointsSetting();
            setStatus(['点数设置已更新：' points_dropdown.Value], 'success');
        catch exception
            handleCommunicationError('点数设置失败', exception);
        end
    end

    function sendSamplePointsSetting()
        if strcmp(points_dropdown.Value, 'Auto')
            writeline(osa, ':SENSE:SWEEP:POINTS:AUTO ON');
        else
            sample_count = str2double(points_dropdown.Value);
            writeline(osa, ':SENSE:SWEEP:POINTS:AUTO OFF');
            writeline(osa, sprintf(':SENSE:SWEEP:POINTS %d', sample_count));
        end
    end

    function sendScanSettings()
        center_m = center_spinner.Value * 1e-9;
        span_m = span_spinner.Value * 1e-9;
        writeline(osa, sprintf(':SENS:WAV:CENT %.12g', center_m));
        writeline(osa, sprintf(':SENS:WAV:SPAN %.12g', span_m));
        rbw_nm = sscanf(rbw_dropdown.Value, '%f');
        writeline(osa, sprintf(':SENS:BANDWIDTH %.3g', rbw_nm * 1e-9));
        mode_map = containers.Map({'NORMAL','MID','HIGH1','HIGH2'}, {6, 2, 3, 4});
        writeline(osa, sprintf(':SENS:SENS %d', mode_map(sensitivity_dropdown.Value)));
        sendSamplePointsSetting();
    end

    function sendTraceSettings()
        traces = {'TRA', 'TRB', 'TRC'};
        states = [trace_a_checkbox.Value, trace_b_checkbox.Value, trace_c_checkbox.Value];
        for trace_setting_index = 1:numel(traces)
            writeline(osa, sprintf(':TRACE:STATE:%s %s', ...
                traces{trace_setting_index}, onOff(states(trace_setting_index))));
        end

        attr_data = {trace_a_attr_dropdown.Value, ...
            trace_b_attr_dropdown.Value, trace_c_attr_dropdown.Value};
        for ti = 1:numel(traces)
            writeline(osa, sprintf(':TRACE:ATTRIBUTE:%s %s', ...
                traces{ti}, attr_data{ti}));
        end

        if math_checkbox.Value
            writeline(osa, ':CALCULATE:MATH:TRC A-B(LOG)');
        end
    end

    function sendSingleSweepAndOpcQuery()
        % AQ6370D 官方定义：SINGLE=1；异步等待 *OPC? 以保持 GUI 响应。
        writeline(osa, ':INITIATE:SMODE SINGLE;:INITIATE');
        writeline(osa, '*OPC?');
    end

    function restoreRepeatSweep()
        % AQ6370D 官方定义：REPEAT=2。连续扫描启动后不等待 *OPC?。
        writeline(osa, ':INITIATE:SMODE REPEAT;:INITIATE');
    end

    function traceAttributeChanged(source, ~)
        persistentSettingChanged();
        if ~is_connected || isempty(osa), return; end
        try
            if source == trace_a_attr_dropdown
                trace_name = 'TRA';
            elseif source == trace_b_attr_dropdown
                trace_name = 'TRB';
            else
                trace_name = 'TRC';
            end
            writeline(osa, sprintf(':TRACE:ATTRIBUTE:%s %s', ...
                trace_name, source.Value));
            setStatus(sprintf('%s 属性已设为 %s', trace_name, source.Value), 'success');
        catch
        end
    end

    function traceSettingChanged(varargin)
        persistentSettingChanged();
        updateYAxisLabels();
        if ~is_connected || isempty(osa), return; end
        try
            sendTraceSettings();
        catch
        end
    end

    %% 采集流程
    function singleAcquisition(~, ~)
        if ~requireConnection() || is_acquiring || is_continuous
            return;
        end
        ensureAcquisitionTimer();
        try
            beginAcquisition('single');
            start(acquisition_timer);
        catch exception
            recovery_message = tryRestoreRepeatSweep();
            handleAcquisitionError(exception, recovery_message);
        end
    end

    function startContinuousAcquisition(~, ~)
        if ~requireConnection() || is_continuous
            return;
        end

        ensureAcquisitionTimer();
        is_continuous = true;
        stop_requested = false;
        cycle_ready_for_restart = false;
        try
            beginAcquisition('continuous');
            setStatus('连续采集已开始：正在执行第一轮 SINGLE', 'success');
            start(acquisition_timer);
        catch exception
            is_continuous = false;
            recovery_message = tryRestoreRepeatSweep();
            handleAcquisitionError(exception, recovery_message);
        end
    end

    function ensureAcquisitionTimer()
        if isempty(acquisition_timer) || ~isvalid(acquisition_timer)
            acquisition_timer = timer( ...
                'ExecutionMode', 'singleShot', ...
                'StartDelay', 0.05, ...
                'BusyMode', 'drop', ...
                'TimerFcn', @acquisitionTimerTick, ...
                'StopFcn', @acquisitionTimerStopped, ...
                'ErrorFcn', @acquisitionTimerError);
        end
    end

    function requestContinuousStop(~, ~)
        if ~is_continuous || stop_requested
            return;
        end
        stop_requested = true;
        updateControlStates();
        if is_acquiring
            acquisition_info.Text = '已请求停止，当前 SINGLE 将作为最后一轮...';
            setStatus('已请求停止：当前轮完成后恢复 REPEAT 连续扫描', 'info');
        else
            acquisition_info.Text = '已请求停止，将执行最后一轮 SINGLE...';
            setStatus('已请求停止：再完成一轮后恢复 REPEAT 连续扫描', 'info');
        end

        % 若恰好处于两轮之间且计时器未运行，补启动一次最终 SINGLE。
        if strcmp(acquisition_phase, 'between_rounds') && ...
                ~isempty(acquisition_timer) && ...
                isvalid(acquisition_timer) && strcmp(acquisition_timer.Running, 'off')
            cycle_ready_for_restart = true;
            start(acquisition_timer);
        end
    end

    function cancelContinuousAcquisition()
        is_continuous = false;
        stop_requested = false;
        cycle_ready_for_restart = false;
        acquisition_phase = 'idle';
        acquisition_context = '';
        pending_traces = {};
        if ~isempty(acquisition_timer) && isvalid(acquisition_timer) && ...
                strcmp(acquisition_timer.Running, 'on')
            stop(acquisition_timer);
        end
        updateControlStates();
    end

    function acquisitionTimerTick(~, ~)
        cycle_ready_for_restart = false;
        try
            if strcmp(acquisition_phase, 'waiting_opc')
                if ~is_connected || isempty(osa)
                    error('等待 *OPC? 时仪器连接已断开。');
                end
                if osa.NumBytesAvailable == 0
                    if toc(opc_wait_clock) >= timeout_spinner.Value
                        error('等待 *OPC? 超时（%.1f 秒）。', timeout_spinner.Value);
                    end
                    cycle_ready_for_restart = true;
                    return;
                end

                operation_complete = strtrim(char(readline(osa)));
                if ~strcmp(operation_complete, '1')
                    error('仪器单次扫描未正常完成，*OPC? 返回：%s', operation_complete);
                end
                completeAcquisition();

                if strcmp(acquisition_context, 'single')
                    finishSingleAcquisition();
                elseif stop_requested
                    finishRequestedContinuousStop();
                elseif is_continuous && is_connected && ~is_closing
                    acquisition_phase = 'between_rounds';
                    is_acquiring = false;
                    updateControlStates();
                    acquisition_info.Text = '本轮数据和绘图已完成，正在开始下一轮...';
                    setStatus('本轮采集及绘图完成，正在开始下一轮 SINGLE', 'success');
                    cycle_ready_for_restart = true;
                end
            elseif strcmp(acquisition_phase, 'between_rounds')
                beginAcquisition('continuous');
                cycle_ready_for_restart = true;
            end
        catch exception
            cycle_ready_for_restart = false;
            is_continuous = false;
            stop_requested = false;
            acquisition_phase = 'idle';
            acquisition_context = '';
            pending_traces = {};
            recovery_message = tryRestoreRepeatSweep();
            handleAcquisitionError(exception, recovery_message);
        end
    end

    function finishSingleAcquisition()
        acquisition_phase = 'idle';
        acquisition_context = '';
        pending_traces = {};
        try
            restoreRepeatSweep();
            setStatus('单次采集和绘图完成，仪器已恢复 REPEAT 连续扫描', 'success');
        catch exception
            setStatus(['单次采集和绘图完成，但恢复 REPEAT 失败：' ...
                exception.message], 'error');
        end
        updateControlStates();
    end

    function finishRequestedContinuousStop()
        is_continuous = false;
        stop_requested = false;
        cycle_ready_for_restart = false;
        acquisition_phase = 'idle';
        acquisition_context = '';
        pending_traces = {};
        try
            restoreRepeatSweep();
            acquisition_info.Text = '最后一轮已完成，仪器正在 REPEAT 连续扫描';
            setStatus('连续采集已停止：最后一轮完成，仪器已恢复 REPEAT', 'success');
        catch exception
            acquisition_info.Text = '最后一轮已完成，但恢复 REPEAT 失败';
            setStatus(['连续采集已停止，但恢复 REPEAT 失败：' ...
                exception.message], 'error');
        end
        updateControlStates();
    end

    function recovery_message = tryRestoreRepeatSweep()
        recovery_message = '';
        if ~is_connected || isempty(osa) || is_closing
            return;
        end
        try
            restoreRepeatSweep();
            recovery_message = '；仪器已恢复 REPEAT 连续扫描';
        catch exception
            recovery_message = ['；恢复 REPEAT 失败：' exception.message];
        end
    end

    function acquisitionTimerStopped(~, ~)
        if ~cycle_ready_for_restart || is_closing || ...
                strcmp(acquisition_phase, 'idle') || ...
                isempty(acquisition_timer) || ~isvalid(acquisition_timer)
            return;
        end
        cycle_ready_for_restart = false;
        try
            start(acquisition_timer);
        catch exception
            is_continuous = false;
            stop_requested = false;
            acquisition_phase = 'idle';
            acquisition_context = '';
            pending_traces = {};
            updateControlStates();
            setStatus(['无法继续采集流程：' exception.message], 'error');
        end
    end

    function acquisitionTimerError(~, event)
        cycle_ready_for_restart = false;
        is_continuous = false;
        stop_requested = false;
        acquisition_phase = 'idle';
        acquisition_context = '';
        pending_traces = {};
        if isprop(event, 'Data') && isa(event.Data, 'MException')
            message = event.Data.message;
        else
            message = '未知计时器错误';
        end
        recovery_message = tryRestoreRepeatSweep();
        handleAcquisitionError(MException('YokogawaOSA:Timer', ...
            ['采集计时器错误：' message]), recovery_message);
    end

    function beginAcquisition(context)
        if is_acquiring
            error('已有采集正在进行。');
        end
        checked_traces = getCheckedTraces();
        if isempty(checked_traces)
            error('未勾选任何 Trace。请至少勾选 TRA/TRB/TRC 中的一个。');
        end

        pending_traces = checked_traces;
        acquisition_context = context;
        acquisition_phase = 'waiting_opc';
        is_acquiring = true;
        setappdata(fig, 'AcquisitionStartedAt', datetime('now'));
        updateControlStates();

        trace_list = strjoin(checked_traces, ', ');
        acquisition_info.Text = ['正在扫描并读取 ' trace_list '...'];
        setStatus(['正在采集 ' trace_list], 'info');

        sendScanSettings();
        sendTraceSettings();
        sendSingleSweepAndOpcQuery();
        opc_wait_clock = tic;
    end

    function completeAcquisition()
        checked_traces = pending_traces;
        if isempty(checked_traces)
            error('没有待读取的 Trace。');
        end
        trace_list = strjoin(checked_traces, ', ');

        % 读取本轮实际配置；点数用于判断响应是否完整。
        rbw_raw = strtrim(writeread(osa, ':SENSE:BANDWIDTH?'));
        sensitivity_raw = strtrim(writeread(osa, ':SENSE:SENSE?'));
        expected_points_raw = strtrim(writeread(osa, ':SENSE:SWEEP:POINTS?'));
        rbw_m = str2double(rbw_raw);
        expected_points = str2double(expected_points_raw);
        if ~isfinite(expected_points) || expected_points < 1 || ...
                expected_points ~= round(expected_points)
            error('仪器返回的扫描点数无效：%s', expected_points_raw);
        end
        expected_points = round(expected_points);
        acquired_at = datetime('now');

        % 循环读取每个被勾选 Trace 的数据
        num_traces = numel(checked_traces);
        trace_data = struct([]);
        for idx = 1:num_traces
            trace_name = checked_traces{idx};

            [x_data_m, y_data] = readCompleteTrace(trace_name, expected_points);

            x_data_nm = x_data_m * 1e9;
            is_loss_trace = strcmp(trace_name, 'TRC') && math_checkbox.Value;
            if is_loss_trace
                y_unit = 'Loss_dB';
                math_expression = 'A-B(LOG)';
            else
                y_unit = 'Power_dBm';
                math_expression = '';
            end

            trace_data(idx).RBW = rbw_raw;
            trace_data(idx).RBWMeters = rbw_m;
            trace_data(idx).ResolutionNm = rbw_m * 1e9;
            trace_data(idx).SENS = sensitivity_raw;
            trace_data(idx).SensitivityMode = str2double(sensitivity_raw);
            trace_data(idx).SensitivityText = formatSensitivity(sensitivity_raw);
            trace_data(idx).XDataMeters = x_data_m(:);
            trace_data(idx).XDataNm = x_data_nm(:);
            trace_data(idx).YData = y_data(:);
            trace_data(idx).Trace = trace_name;
            trace_data(idx).TraceAttribute = getTraceAttribute(trace_name);
            trace_data(idx).IsLossTrace = is_loss_trace;
            trace_data(idx).MathEnabled = math_checkbox.Value;
            trace_data(idx).MathExpression = math_expression;
            trace_data(idx).YUnit = y_unit;
            trace_data(idx).InstrumentID = instrument_id;
            trace_data(idx).CenterWavelengthNm = center_spinner.Value;
            trace_data(idx).SpanNm = span_spinner.Value;
            trace_data(idx).SamplePointsSetting = points_dropdown.Value;
            trace_data(idx).ExpectedPoints = expected_points;
            trace_data(idx).ActualPoints = numel(y_data);
            trace_data(idx).AcquiredAt = acquired_at;
        end

        latest_data = trace_data;

        % 三条 Trace 固定绘制在 GUI 内的三个独立图轴中，不再创建弹窗。
        all_trace_names = {'TRA', 'TRB', 'TRC'};
        for axis_index = 1:3
            data_index = find(strcmp({trace_data.Trace}, ...
                all_trace_names{axis_index}), 1);
            if isempty(data_index)
                set(plot_lines(axis_index), 'XData', NaN, 'YData', NaN);
                title(axes_handles(axis_index), ...
                    [all_trace_names{axis_index} ' - 未采集'], ...
                    'Interpreter', 'none', 'FontSize', 16);
                ylabel(axes_handles(axis_index), 'Power (dBm)', ...
                    'FontWeight', 'bold', 'FontSize', 15);
                continue;
            end

            td = trace_data(data_index);
            set(plot_lines(axis_index), 'XData', td.XDataNm, 'YData', td.YData, ...
                'Color', traceColor(td.Trace));
            if td.IsLossTrace
                ylabel(axes_handles(axis_index), 'Loss (dB)', ...
                    'FontWeight', 'bold', 'FontSize', 15);
            else
                ylabel(axes_handles(axis_index), 'Power (dBm)', ...
                    'FontWeight', 'bold', 'FontSize', 15);
            end
            title(axes_handles(axis_index), sprintf('%s - %s', td.Trace, instrument_id), ...
                'Interpreter', 'none', 'FontSize', 16);
        end
        applyAxisLimits();
        if ~any(strcmp(checked_traces, plot_tabs.SelectedTab.Title))
            first_tab_index = find(strcmp(all_trace_names, checked_traces{1}), 1);
            plot_tabs.SelectedTab = trace_tabs(first_tab_index);
        end
        drawnow;

        % 更新保存面板 Trace 勾选状态
        updateSaveTraceStates();

        % 更新信息显示
        rbw_display = formatRBW(rbw_m, rbw_raw);
        sens_display = formatSensitivity(sensitivity_raw);
        rbw_dropdown.Value = validChoice(rbw_display, rbw_dropdown.Items, rbw_dropdown.Value);
        sensitivity_dropdown.Value = validChoice(sens_display, sensitivity_dropdown.Items, sensitivity_dropdown.Value);
        plot_info.Text = sprintf('%s | Res %s | SENS %s | %s', ...
            trace_list, rbw_display, sens_display, ...
            char(datetime(acquired_at, 'Format', 'yyyy-MM-dd HH:mm:ss')));
        point_parts = arrayfun(@(td) sprintf('%s %d', ...
            td.Trace, numel(td.YData)), trace_data, 'UniformOutput', false);
        points_status.Text = ['作图点数：' strjoin(point_parts, '，')];
        acquisition_info.Text = sprintf('已读取 %s 共 %d 点', ...
            trace_list, numel(trace_data(1).YData));
        save_button.Enable = 'on';
        drawnow;

        completed_acquisition_count = completed_acquisition_count + 1;
        setappdata(fig, 'AcquisitionCompletedAt', datetime('now'));
        setappdata(fig, 'CompletedAcquisitions', completed_acquisition_count);

        finishAcquisition();
    end

    function [x_data_m, y_data] = readCompleteTrace(trace_name, expected_points)
        max_attempts = 3;
        last_message = '未收到数据';
        x_count = 0;
        y_count = 0;

        for attempt = 1:max_attempts
            try
                x_response = writeread(osa, sprintf(':TRACE:X? %s', trace_name));
                y_response = writeread(osa, sprintf(':TRACE:Y? %s', trace_name));
                x_data_m = parseNumericList(x_response, ['X Trace ' trace_name]);
                y_data = parseNumericList(y_response, ['Y Trace ' trace_name]);
                x_count = numel(x_data_m);
                y_count = numel(y_data);
                if x_count == expected_points && y_count == expected_points
                    return;
                end
                last_message = sprintf('期望 %d 点，收到 X=%d、Y=%d', ...
                    expected_points, x_count, y_count);
            catch exception
                last_message = exception.message;
            end

            if attempt < max_attempts
                setStatus(sprintf('%s 数据不完整，正在重试（%d/%d）', ...
                    trace_name, attempt + 1, max_attempts), 'info');
                try
                    flush(osa);
                catch
                end
                pause(0.1);
            end
        end

        error('Trace %s 数据接收失败，已重试 %d 次。%s；最后收到 X=%d、Y=%d。', ...
            trace_name, max_attempts, last_message, x_count, y_count);
    end

    function attribute = getTraceAttribute(trace_name)
        switch trace_name
            case 'TRA'
                attribute = trace_a_attr_dropdown.Value;
            case 'TRB'
                attribute = trace_b_attr_dropdown.Value;
            otherwise
                attribute = trace_c_attr_dropdown.Value;
        end
    end

    function finishAcquisition()
        is_acquiring = false;
        updateControlStates();
    end

    function updateSaveTraceStates()
        % 根据 latest_data 更新保存面板的 Trace 勾选框
        traces_available = {latest_data.Trace};
        trace_names = {'TRA', 'TRB', 'TRC'};
        checkboxes = {save_tra_checkbox, save_trb_checkbox, save_trc_checkbox};
        for i = 1:3
            has_data = any(strcmp(traces_available, trace_names{i}));
            if has_data
                checkboxes{i}.Enable = 'on';
                checkboxes{i}.Value = true;
            else
                checkboxes{i}.Enable = 'off';
                checkboxes{i}.Value = false;
            end
        end
    end

    function traces = getCheckedTraces()
        traces = {};
        if trace_a_checkbox.Value, traces{end+1} = 'TRA'; end
        if trace_b_checkbox.Value, traces{end+1} = 'TRB'; end
        if trace_c_checkbox.Value, traces{end+1} = 'TRC'; end
    end

    function handleAcquisitionError(exception, recovery_message)
        if nargin < 2
            recovery_message = '';
        end
        is_acquiring = false;
        is_continuous = false;
        stop_requested = false;
        cycle_ready_for_restart = false;
        acquisition_phase = 'idle';
        acquisition_context = '';
        pending_traces = {};
        acquisition_info.Text = '采集失败';
        updateControlStates();
        setStatus(['采集失败：' exception.message recovery_message], 'error');
    end

    %% 保存数据
    function chooseOutputFolder(~, ~)
        selected_folder = uigetdir(output_folder_field.Value, '选择 OSA 数据保存目录');
        if isequal(selected_folder, 0)
            return;
        end
        output_folder_field.Value = selected_folder;
        persistentSettingChanged();
    end

    function saveCurrentData(~, ~)
        if isempty(latest_data)
            setStatus('当前没有可保存的采集数据', 'error');
            return;
        end

        % 根据保存面板勾选框确定要保存的 Trace
        trace_map = containers.Map({'TRA','TRB','TRC'}, ...
            {save_tra_checkbox, save_trb_checkbox, save_trc_checkbox});
        data_trace_names = {latest_data.Trace};
        save_indices = [];
        for i = 1:numel(data_trace_names)
            tn = data_trace_names{i};
            if trace_map.isKey(tn) && trace_map(tn).Value
                save_indices(end+1) = i;
            end
        end

        if isempty(save_indices)
            setStatus('请在「保存设置」中勾选至少一个 Trace', 'error');
            return;
        end

        % 检查保存格式
        save_mat = save_mat_checkbox.Value;
        save_csv = save_csv_checkbox.Value;
        if ~save_mat && ~save_csv
            setStatus('请至少勾选一种保存格式（MAT 或 CSV）', 'error');
            return;
        end

        save_rbw = save_rbw_checkbox.Value;
        save_sens = save_sens_checkbox.Value;

        try
            output_folder = strtrim(output_folder_field.Value);
            if isempty(output_folder)
                error('保存目录不能为空。');
            end
            if ~isfolder(output_folder)
                mkdir(output_folder);
            end

            base_name = sanitizeFileName(base_name_field.Value);
            if isempty(base_name)
                base_name = 'OSA_trace';
            end

            saved_count = 0;
            for idx = save_indices
                td = latest_data(idx);

                file_stem = fullfile(output_folder, ...
                    sprintf('%s_%s', base_name, td.Trace));
                % 重名时自动追加 _1, _2...
                c = 1;
                while isfile([file_stem '.mat']) || isfile([file_stem '.csv'])
                    file_stem = fullfile(output_folder, ...
                        sprintf('%s_%s_%d', base_name, td.Trace, c));
                    c = c + 1;
                end

                XDataNm = td.XDataNm;
                YData = td.YData;
                Trace = td.Trace;
                InstrumentID = td.InstrumentID;
                CenterWavelengthNm = td.CenterWavelengthNm;
                SpanNm = td.SpanNm;
                AcquiredAt = td.AcquiredAt;
                IsLossTrace = td.IsLossTrace;

                if save_mat
                    mat_vars = {'XDataNm', 'YData', 'Trace', 'InstrumentID', ...
                        'CenterWavelengthNm', 'SpanNm', 'AcquiredAt', 'IsLossTrace'};
                    if save_rbw
                        RBW = td.RBW;
                        RBWMeters = td.RBWMeters;
                        mat_vars = [mat_vars, {'RBW', 'RBWMeters'}];
                    end
                    if save_sens
                        SENS = td.SENS;
                        SensitivityMode = td.SensitivityMode;
                        mat_vars = [mat_vars, {'SENS', 'SensitivityMode'}];
                    end
                    save([file_stem '.mat'], mat_vars{:});
                end

                if save_csv
                    writeTraceCsv([file_stem '.csv'], td);
                end

                saved_count = saved_count + 1;
            end

            persistentSettingChanged();

            formats = {};
            if save_mat, formats{end+1} = '.mat'; end
            if save_csv, formats{end+1} = '.csv'; end
            setStatus(sprintf('保存成功：已保存 %d 个 Trace（%s），目录：%s', ...
                saved_count, strjoin(formats, ' + '), output_folder), 'success');
        catch exception
            setStatus(['保存失败：' exception.message], 'error');
        end
    end

    function writeTraceCsv(file_name, trace_data)
        [file_id, error_message] = fopen(file_name, 'w', 'n', 'UTF-8');
        if file_id < 0
            error('无法创建 CSV 文件：%s', error_message);
        end
        file_cleanup = onCleanup(@() fclose(file_id));

        acquired_text = char(datetime(trace_data.AcquiredAt, ...
            'Format', 'yyyy-MM-dd HH:mm:ss.SSS'));
        metadata = {
            'InstrumentID', trace_data.InstrumentID;
            'AcquiredAt', acquired_text;
            'Trace', trace_data.Trace;
            'TraceAttribute', trace_data.TraceAttribute;
            'CenterWavelength_nm', trace_data.CenterWavelengthNm;
            'Span_nm', trace_data.SpanNm;
            'Resolution_nm', trace_data.ResolutionNm;
            'Sensitivity', trace_data.SensitivityText;
            'SamplePointsSetting', trace_data.SamplePointsSetting;
            'ExpectedPoints', trace_data.ExpectedPoints;
            'ActualPoints', trace_data.ActualPoints;
            'MathEnabled', trace_data.MathEnabled;
            'MathExpression', trace_data.MathExpression;
            'YUnit', trace_data.YUnit
        };

        for metadata_index = 1:size(metadata, 1)
            fprintf(file_id, '# %s,%s\n', metadata{metadata_index, 1}, ...
                csvValue(metadata{metadata_index, 2}));
        end
        fprintf(file_id, '\nWavelength_nm,%s\n', trace_data.YUnit);
        fprintf(file_id, '%.15g,%.15g\n', ...
            [trace_data.XDataNm(:).'; trace_data.YData(:).']);
        clear file_cleanup;
    end

    %% 状态与持久化
    function updateControlStates()
        connected_state = onOff(is_connected);
        idle_connected_state = onOff(is_connected && ~is_acquiring && ~is_continuous);

        ip_field.Enable = onOff(~is_connected);
        port_spinner.Enable = onOff(~is_connected);
        timeout_spinner.Enable = onOff(~is_connected);
        connect_button.Enable = 'on';
        rbw_dropdown.Enable = connected_state;
        sensitivity_dropdown.Enable = connected_state;
        points_dropdown.Enable = connected_state;
        single_button.Enable = idle_connected_state;
        start_button.Enable = idle_connected_state;
        stop_button.Enable = onOff(is_connected && is_continuous && ~stop_requested);

        if is_acquiring
            single_button.Text = '采集中...';
        else
            single_button.Text = '单次采集';
        end
        if stop_requested
            stop_button.Text = '等待最后一轮...';
        else
            stop_button.Text = '停止连续采集';
        end
    end

    function updateYAxisLabels()
        trace_names_local = {'TRA', 'TRB', 'TRC'};
        for axis_index = 1:3
            is_loss = strcmp(trace_names_local{axis_index}, 'TRC') && math_checkbox.Value;
            if ~isempty(latest_data)
                data_index = find(strcmp({latest_data.Trace}, ...
                    trace_names_local{axis_index}), 1);
                if ~isempty(data_index)
                    is_loss = latest_data(data_index).IsLossTrace;
                end
            end
            if is_loss
                ylabel(axes_handles(axis_index), 'Loss (dB)', ...
                    'FontWeight', 'bold', 'FontSize', 15);
            else
                ylabel(axes_handles(axis_index), 'Power (dBm)', ...
                    'FontWeight', 'bold', 'FontSize', 15);
            end
        end
    end

    function axisLimitsChanged(~, ~)
        if ~x_limit_auto.Value && x_limit_min.Value >= x_limit_max.Value
            x_limit_min.Value = settings.xLimitMin;
            x_limit_max.Value = settings.xLimitMax;
            setStatus('X 轴范围无效：Min 必须小于 Max', 'error');
            return;
        end
        if ~y_limit_auto.Value && y_limit_min.Value >= y_limit_max.Value
            y_limit_min.Value = settings.yLimitMin;
            y_limit_max.Value = settings.yLimitMax;
            setStatus('Y 轴范围无效：Min 必须小于 Max', 'error');
            return;
        end
        updateAxisLimitControls();
        persistentSettingChanged();
        applyAxisLimits();
        drawnow limitrate;
    end

    function updateAxisLimitControls()
        x_manual_state = onOff(~x_limit_auto.Value);
        y_manual_state = onOff(~y_limit_auto.Value);
        x_limit_min.Enable = x_manual_state;
        x_limit_max.Enable = x_manual_state;
        y_limit_min.Enable = y_manual_state;
        y_limit_max.Enable = y_manual_state;
    end

    function applyAxisLimits()
        for limit_axis_index = 1:numel(axes_handles)
            if x_limit_auto.Value
                xlim(axes_handles(limit_axis_index), 'tight');
            else
                xlim(axes_handles(limit_axis_index), ...
                    [x_limit_min.Value, x_limit_max.Value]);
            end
            if y_limit_auto.Value
                ylim(axes_handles(limit_axis_index), 'auto');
            else
                ylim(axes_handles(limit_axis_index), ...
                    [y_limit_min.Value, y_limit_max.Value]);
            end
        end
    end

    function persistentSettingChanged(varargin)
        settings.ipAddress = strtrim(ip_field.Value);
        settings.port = port_spinner.Value;
        settings.timeout = timeout_spinner.Value;
        settings.centerNm = center_spinner.Value;
        settings.spanNm = span_spinner.Value;
        settings.rbwNm = rbw_dropdown.Value;
        settings.sensitivityMode = sensitivity_dropdown.Value;
        settings.samplePoints = points_dropdown.Value;
        settings.traceAAttr = trace_a_attr_dropdown.Value;
        settings.traceBAttr = trace_b_attr_dropdown.Value;
        settings.traceCAttr = trace_c_attr_dropdown.Value;
        settings.traceAOn = trace_a_checkbox.Value;
        settings.traceBOn = trace_b_checkbox.Value;
        settings.traceCOn = trace_c_checkbox.Value;
        settings.mathEnabled = math_checkbox.Value;
        settings.outputFolder = output_folder_field.Value;
        settings.baseName = base_name_field.Value;
        settings.saveMat = save_mat_checkbox.Value;
        settings.saveCsv = save_csv_checkbox.Value;
        settings.saveTra = save_tra_checkbox.Value;
        settings.saveTrb = save_trb_checkbox.Value;
        settings.saveTrc = save_trc_checkbox.Value;
        settings.saveRbw = save_rbw_checkbox.Value;
        settings.saveSens = save_sens_checkbox.Value;
        settings.xLimitAuto = x_limit_auto.Value;
        settings.xLimitMin = x_limit_min.Value;
        settings.xLimitMax = x_limit_max.Value;
        settings.yLimitAuto = y_limit_auto.Value;
        settings.yLimitMin = y_limit_min.Value;
        settings.yLimitMax = y_limit_max.Value;
        settings.windowPosition = fig.Position;
        try
            setpref(preference_group, 'Settings', settings);
        catch
            % 偏好写入失败不应中断仪器控制。
        end
    end

    function saveWindowPosition(varargin)
        if isvalid(fig)
            persistentSettingChanged();
        end
    end

    function setStatus(message, status_type)
        status_label.Text = message;
        switch status_type
            case 'success'
                status_label.FontColor = [0.05, 0.48, 0.18];
            case 'error'
                status_label.FontColor = [0.75, 0.12, 0.12];
            otherwise
                status_label.FontColor = [0.25, 0.25, 0.25];
        end
        drawnow limitrate;
    end

    function connected = requireConnection()
        connected = is_connected && ~isempty(osa);
        if ~connected
            setStatus('请先连接光谱仪', 'error');
        end
    end

    function handleCommunicationError(prefix, exception)
        setStatus([prefix '：' exception.message], 'error');
        if ~isempty(osa)
            try
                writeread(osa, '*IDN?');
            catch
                disconnectInstrument('通信已中断，请重新连接');
            end
        end
    end

    function closeGUI(~, ~)
        is_closing = true;
        is_continuous = false;
        stop_requested = false;
        cycle_ready_for_restart = false;
        acquisition_phase = 'idle';
        acquisition_context = '';
        pending_traces = {};
        if ~isempty(acquisition_timer) && isvalid(acquisition_timer)
            if strcmp(acquisition_timer.Running, 'on')
                stop(acquisition_timer);
            end
            delete(acquisition_timer);
        end
        persistentSettingChanged();
        osa = [];
        delete(fig);
    end
end

function encoded = csvValue(value)
%CSVVALUE 将标量转换为带引号且可安全写入 CSV 的文本。
    if islogical(value)
        if value
            text = 'true';
        else
            text = 'false';
        end
    elseif isnumeric(value)
        text = sprintf('%.15g', value);
    elseif isstring(value)
        text = char(value);
    else
        text = char(value);
    end
    text = strrep(text, sprintf('\r'), ' ');
    text = strrep(text, sprintf('\n'), ' ');
    text = strrep(text, '"', '""');
    encoded = ['"' text '"'];
end

function values = parseNumericList(response, label)
%PARSENUMERICLIST 安全解析 OSA 返回的逗号或空白分隔数值。
    response_text = strtrim(char(response));
    if isempty(response_text)
        error('%s 返回为空。', label);
    end
    tokens = regexp(response_text, '[,;\s]+', 'split');
    tokens = tokens(~cellfun('isempty', tokens));
    values = str2double(tokens);
    if isempty(values) || any(~isfinite(values))
        error('%s 包含无法解析的数值。', label);
    end
    values = values(:).';
end

function text = formatRBW(rbw_m, raw_value)
%FORMATRBW 将分辨率带宽转换为便于阅读的 nm 文本。
    if isfinite(rbw_m)
        text = sprintf('%.6g nm', rbw_m * 1e9);
    else
        text = raw_value;
    end
end

function text = formatSensitivity(raw_value)
%FORMATSENSITIVITY 将 AQ6370D SENS 模式码转为可读文本。
%   映射：2->MID, 6->NORMAL, 3->HIGH1, 4->HIGH2
    numeric_val = str2double(raw_value);
    if isnan(numeric_val) || ~isfinite(numeric_val)
        text = raw_value;
        return;
    end
    switch numeric_val
        case 2,  text = 'MID';
        case 6,  text = 'NORMAL';
        case 3,  text = 'HIGH1';
        case 4,  text = 'HIGH2';
        otherwise, text = raw_value;
    end
end

function col = traceColor(trace_name)
%TRACECOLOR 为不同 Trace 返回区分颜色。
    switch upper(trace_name)
        case 'TRA', col = [0.00, 0.45, 0.74];
        case 'TRB', col = [0.85, 0.33, 0.10];
        case 'TRC', col = [0.47, 0.67, 0.19];
        otherwise,  col = [0, 0, 0];
    end
end

function result = onOff(value)
%ONOFF 将逻辑值转换为 MATLAB UI/SCPI 通用的 on/off 文本。
    if value
        result = 'on';
    else
        result = 'off';
    end
end

function addLabel(parent, text, row, column)
%ADDLABEL 创建右对齐标签并放置到网格。
    label = uilabel(parent, ...
        'Text', text, ...
        'HorizontalAlignment', 'right');
    label.Layout.Row = row;
    label.Layout.Column = column;
end

function name = sanitizeFileName(name)
%SANITIZEFILENAME 移除 Windows 文件名中的非法字符。
    name = strtrim(char(name));
    name = regexprep(name, '[<>:"/\\|?*]', '_');
    name = regexprep(name, '[\. ]+$', '');
end

function settings = loadSettings(preference_group, default_folder)
%LOADSETTINGS 读取并校验 GUI 持久化设置。
    settings = struct( ...
        'ipAddress', '192.168.3.63', ...
        'port', 10001, ...
        'timeout', 5, ...
        'centerNm', 1310, ...
        'spanNm', 100, ...
        'rbwNm', '0.02 nm', ...
        'sensitivityMode', 'NORMAL', ...
        'samplePoints', 'Auto', ...
        'traceAttribute', 'WRITE', ...
        'traceAAttr', 'WRITE', ...
        'traceBAttr', 'WRITE', ...
        'traceCAttr', 'WRITE', ...
        'traceAOn', true, ...
        'traceBOn', false, ...
        'traceCOn', false, ...
        'mathEnabled', false, ...
        'outputFolder', default_folder, ...
        'baseName', 'OSA_trace', ...
        'saveMat', true, ...
        'saveCsv', true, ...
        'saveTra', true, ...
        'saveTrb', false, ...
        'saveTrc', false, ...
        'saveRbw', true, ...
        'saveSens', true, ...
        'xLimitAuto', true, ...
        'xLimitMin', 1260, ...
        'xLimitMax', 1360, ...
        'yLimitAuto', true, ...
        'yLimitMin', -100, ...
        'yLimitMax', 0, ...
        'windowPosition', [70, 50, 1280, 790]);

    if ispref(preference_group, 'Settings')
        try
            saved = getpref(preference_group, 'Settings');
            fields = fieldnames(settings);
            for index = 1:numel(fields)
                field = fields{index};
                if isstruct(saved) && isfield(saved, field)
                    settings.(field) = saved.(field);
                end
            end
        catch
            % 使用默认设置。
        end
    end

    settings.ipAddress = validText(settings.ipAddress, '192.168.3.63');
    settings.port = boundedNumber(settings.port, 1, 65535, 10001, true);
    settings.timeout = boundedNumber(settings.timeout, 1, 120, 5, true);
    settings.centerNm = boundedNumber(settings.centerNm, 600, 2400, 1310, false);
    settings.spanNm = boundedNumber(settings.spanNm, 0.01, 2000, 100, false);
    settings.rbwNm = validChoice(settings.rbwNm, ...
        {'0.02 nm','0.05 nm','0.1 nm','0.2 nm','0.5 nm','1 nm','2 nm'}, '0.02 nm');
    settings.sensitivityMode = validChoice(settings.sensitivityMode, ...
        {'NORMAL','MID','HIGH1','HIGH2'}, 'NORMAL');
    settings.samplePoints = validChoice(settings.samplePoints, ...
        {'Auto','101','201','501','1001','2001','5001','10001','20001','50001'}, ...
        'Auto');
    settings.traceAttribute = validChoice(settings.traceAttribute, {'WRITE', 'FIX'}, 'WRITE');
    settings.traceAAttr = validChoice(settings.traceAAttr, {'WRITE', 'FIX'}, 'WRITE');
    settings.traceBAttr = validChoice(settings.traceBAttr, {'WRITE', 'FIX'}, 'WRITE');
    settings.traceCAttr = validChoice(settings.traceCAttr, {'WRITE', 'FIX'}, 'WRITE');
    settings.traceAOn = logicalScalar(settings.traceAOn, true);
    settings.traceBOn = logicalScalar(settings.traceBOn, false);
    settings.traceCOn = logicalScalar(settings.traceCOn, false);
    settings.mathEnabled = logicalScalar(settings.mathEnabled, false);
    settings.outputFolder = validText(settings.outputFolder, default_folder);
    settings.baseName = validText(settings.baseName, 'OSA_trace');
    settings.saveMat = logicalScalar(settings.saveMat, true);
    settings.saveCsv = logicalScalar(settings.saveCsv, true);
    settings.saveTra = logicalScalar(settings.saveTra, true);
    settings.saveTrb = logicalScalar(settings.saveTrb, false);
    settings.saveTrc = logicalScalar(settings.saveTrc, false);
    settings.saveRbw = logicalScalar(settings.saveRbw, true);
    settings.saveSens = logicalScalar(settings.saveSens, true);
    settings.xLimitAuto = logicalScalar(settings.xLimitAuto, true);
    settings.xLimitMin = boundedNumber(settings.xLimitMin, -1e9, 1e9, 1260, false);
    settings.xLimitMax = boundedNumber(settings.xLimitMax, -1e9, 1e9, 1360, false);
    if settings.xLimitMin >= settings.xLimitMax
        settings.xLimitMin = 1260;
        settings.xLimitMax = 1360;
    end
    settings.yLimitAuto = logicalScalar(settings.yLimitAuto, true);
    settings.yLimitMin = boundedNumber(settings.yLimitMin, -1e9, 1e9, -100, false);
    settings.yLimitMax = boundedNumber(settings.yLimitMax, -1e9, 1e9, 0, false);
    if settings.yLimitMin >= settings.yLimitMax
        settings.yLimitMin = -100;
        settings.yLimitMax = 0;
    end

    position = settings.windowPosition;
    if ~(isnumeric(position) && isequal(size(position), [1, 4]) && ...
            all(isfinite(position)) && position(3) >= 980 && position(4) >= 680)
        settings.windowPosition = [70, 50, 1280, 790];
    end
end

function value = validText(value, fallback)
    if isstring(value) && isscalar(value)
        value = char(value);
    end
    if ~ischar(value) || isempty(strtrim(value))
        value = fallback;
    end
end

function value = validChoice(value, choices, fallback)
    value = validText(value, fallback);
    if ~any(strcmp(value, choices))
        value = fallback;
    end
end

function value = boundedNumber(value, minimum, maximum, fallback, make_integer)
    if ~(isnumeric(value) && isscalar(value) && isfinite(value) && ...
            value >= minimum && value <= maximum)
        value = fallback;
    end
    if make_integer
        value = round(value);
    end
end

function value = logicalScalar(value, fallback)
    if islogical(value) && isscalar(value)
        return;
    end
    if isnumeric(value) && isscalar(value) && any(value == [0, 1])
        value = logical(value);
    else
        value = fallback;
    end
end
