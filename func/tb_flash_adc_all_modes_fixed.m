%% tb_flash_adc_all_modes_fixed.m
%%%% 修正版统一 TB
%%%%
%%%% 功能：
%%%% 1) 调用 kbits_flash_adc_leftrise_offset() 完成 4 种模式仿真
%%%% 2) 静态分析与动态显示分离
%%%% 3) Missing Code / DNL / INL 全部基于同一份静态 ramp 数据
%%%% 4) 对 mode 3/4（含亚稳态），每个 vin 重复采样取众数
%%%% 5) DNL 图中失码直接依据 missing_codes 标红
%%%% 6) DNL/INL 采用“直接码宽法”，保证和左侧传输曲线一致
%%%%
%%%% 模式定义：
%%%%   1 -> Independent Offset
%%%%   2 -> Correlated Offset
%%%%   3 -> Metastability
%%%%   4 -> Correlated Offset + Metastability

tic;
clear; clc; close all;
rng('shuffle');

%% =========================================================
% 1) 基本参数
%% =========================================================
k_bits    = 4;               % ADC 位数
v_ref     = 1;               % 输入范围 [-v_ref, v_ref]
vos_sigma = 0.25;             % 失调 / 亚稳态强度,代表比较器的随机噪声 / 工艺偏差强度,
n_codes   = 2^k_bits;        % 总码数
delta     = 2 * v_ref / n_codes; %1 个 LSB(最小量化间隔)

%% =========================================================
% 2) 静态分析参数
%% =========================================================
N_STATIC = 4000;                         % 静态 ramp 采样点数
v_in_static = linspace(-v_ref, v_ref, N_STATIC);

% 含亚稳态模式下，每个 vin 重复采样次数
N_REPEAT_META = 25;

%% =========================================================
% 3) 动态显示参数（仅用于时域图）
%% =========================================================
N_DYNAMIC = 2e5;
ramp_periods = 5;
t_dyn = linspace(0, ramp_periods, N_DYNAMIC);
v_in_dyn = -v_ref + (2 * v_ref) * rem(t_dyn, 1);

%% =========================================================
% 4) 绘图布局
%% =========================================================
figure('Color','w','Position',[80,40,1650,1000]);
tiledlayout(4,4,'Padding','compact','TileSpacing','compact');
sgtitle('Flash ADC 4 Modes - Static Missing Code / DNL / INL + Dynamic Waveform', ...
    'FontSize', 16, 'FontWeight', 'bold');

%% =========================================================
% 5) 模式循环
%% =========================================================
for offset_selection = 1:4

    %% -----------------------------------------------------
    % 5.1 为当前模式生成固定的比较器失调
    %
    % ※※※※※※注意：※※※※※※
    % - vos_arr 对应“同一个 ADC 实例”
    % - 不能在每个 vin 上都重新生成
    % - mode 3 只考虑亚稳态，因此静态 offset = 0
    %% -----------------------------------------------------
    n_comp = n_codes - 1;

    switch offset_selection
        case 1
            % Mode 1: Independent Offset
            vos_arr = vos_sigma * randn(1, n_comp);

        case 2
            % Mode 2: Correlated Offset
            v_global = vos_sigma * randn;
            v_local  = 3 * vos_sigma * randn(1, n_comp);
            vos_arr = v_global + v_local;

        case 3
            % Mode 3: Metastability
            vos_arr = zeros(1, n_comp);

        case 4
            % Mode 4: Correlated Offset + Metastability
            v_global = vos_sigma * randn;
            v_local  = 3 * vos_sigma * randn(1, n_comp);
            vos_arr = v_global + v_local;

        otherwise
            error('offset_selection 必须属于 {1,2,3,4}');
    end

    %% -----------------------------------------------------
    % 5.2 模式名称
    %% -----------------------------------------------------
    switch offset_selection
        case 1
            mode_name = 'Mode 1: Independent Offset';
        case 2
            mode_name = 'Mode 2: Correlated Offset';
        case 3
            mode_name = 'Mode 3: Metastability';
        case 4
            mode_name = 'Mode 4: Corr Offset + Metastability';
    end

    %% -----------------------------------------------------
    % 5.3 静态分析
    %
    % code_static 是整份静态分析的唯一依据：
    %   - 传输曲线
    %   - Missing Code
    %   - DNL
    %   - INL
    %
    % mode 3/4：
    %   每个 vin 重复采样，取众数作为代表码
    %% -----------------------------------------------------
    % 初始化：存储静态斜坡输入对应的所有输出码
    code_static = zeros(1, N_STATIC);
    
    % 判断当前是否是【亚稳态模式】（Mode3 / Mode4）
    is_meta_mode = ismember(offset_selection, [3, 4]);
    
    % ===================== 分支1：无亚稳态（Mode1 / Mode2） =====================
    if ~is_meta_mode
        % 每个电压点只需要采样1次，输出稳定、不随机
        for idx = 1:N_STATIC
            [code_static(idx), ~] = kbits_flash_adc_leftrise_offset( ...
                v_in_static(idx), v_ref, k_bits, vos_arr, offset_selection, vos_sigma);
        end
    
    % ===================== 分支2：有亚稳态（Mode3 / Mode4） =====================
    % 亚稳态会让同一个电压，输出不同的码 → 静态测试需要唯一确定的码,必须用 “多次采样取众数” 消除随机抖动！
    else
        % 对每个输入电压 vin，重复采样 N_REPEAT_META 次（例如25次）
        for idx = 1:N_STATIC
            code_rep = zeros(1, N_REPEAT_META); % 存储多次采样结果,长度 = 采样点数（4000 点）
    
            % 多次重复采样
            for r = 1:N_REPEAT_META
                [code_rep(r), ~] = kbits_flash_adc_leftrise_offset( ...
                    v_in_static(idx), v_ref, k_bits, vos_arr, offset_selection, vos_sigma);
            end
    
            % 数据安全处理
            code_rep = round(code_rep); % round() = 四舍五入，强制变成整数
            code_rep = min(max(code_rep, 0), n_codes - 1); % 把码值 “钳位” 在合法范围 [0, 总码数 - 1] 内
    
            % 核心：取【众数】作为该电压的稳定输出码
            code_static(idx) = mode(code_rep);
        end
    end
    % 保险裁剪：双重保护，确保输出码 100% 合法
    code_static = round(code_static);             % 1. 确保是整数
    code_static = min(max(code_static, 0), n_codes - 1);  % 2. 确保在 [0, 最大码] 范围内
    
    % 由最终合法的数字码，反推输出量化电压
    % 作用：让【传输曲线图】和【DNL/INL计算】完全使用同一套数据，绝对一致
    v_out_static_plot = -v_ref + code_static * delta;

    %% -----------------------------------------------------
    % 5.4 动态时域数据（仅用于显示）
    %% -----------------------------------------------------
    v_out_dyn = zeros(1, N_DYNAMIC);

    for idx = 1:N_DYNAMIC
        [~, v_out_dyn(idx)] = kbits_flash_adc_leftrise_offset( ...
            v_in_dyn(idx), v_ref, k_bits, vos_arr, offset_selection, vos_sigma);
    end

    %% -----------------------------------------------------
    % 5.5 静态传输曲线
    %% -----------------------------------------------------
    nexttile;
    hold on;

    % 理想线性参考线
    fplot(@(x) x, [-v_ref, v_ref], 'k--', 'LineWidth', 1);

    % 实际量化曲线
    stairs(v_in_static, v_out_static_plot, 'k-', 'LineWidth', 1.5);

    % 理想量化曲线
    x_ideal = linspace(-v_ref, v_ref, 1000);
    ideal_code = floor((x_ideal + v_ref) / delta);
    ideal_code(ideal_code < 0) = 0;
    ideal_code(ideal_code > n_codes - 1) = n_codes - 1;
    ideal_q = -v_ref + ideal_code * delta;
    stairs(x_ideal, ideal_q, 'r-', 'LineWidth', 1.5);

    hold off;
    grid on; box on;
    title(mode_name);
    xlabel('v_{in}');
    ylabel('v_{out}');
    legend('Ideal Linear', 'Actual Quant', 'Ideal Quant', 'Location', 'best');

    %% -----------------------------------------------------
    % 5.6 计算 Missing Code / DNL / INL
    %
    % 关键修正：
    % 不再采用“先提阈值再反推码宽”的方法，
    % 而是直接统计每个 code 在静态 ramp 上占据的输入区间宽度
    %% -----------------------------------------------------
    [DNL, INL, missing_codes, wide_codes, code_widths] = ...
        calc_dnl_inl_from_static_ramp(v_in_static, code_static, v_ref, n_codes);

    %% -----------------------------------------------------
    % 5.7 打印结果
    %% -----------------------------------------------------
    fprintf('=== %s ===\n', mode_name);

    if isempty(missing_codes)
        fprintf('✓ 未检测到失码\n');
    else
        fprintf('⚠ 检测到失码: %s\n', mat2str(missing_codes));
    end

    if ~isempty(wide_codes)
        fprintf('⚠ 码宽过大的码: %s\n', mat2str(wide_codes));
    end

    fprintf('各码宽(LSB): %s\n', mat2str(code_widths / delta, 4));

    DNL_valid = DNL(~isnan(DNL));
    INL_valid = INL(~isnan(INL));

    if ~isempty(DNL_valid)
        fprintf('DNL range: [%.4f, %.4f] LSB\n', min(DNL_valid), max(DNL_valid));
    else
        fprintf('DNL range: 无有效值\n');
    end

    if ~isempty(INL_valid)
        fprintf('INL range: [%.4f, %.4f] LSB\n', min(INL_valid), max(INL_valid));
    else
        fprintf('INL range: 无有效值\n');
    end

    fprintf('------------------------------------\n\n');

    %% -----------------------------------------------------
    % 5.8 DNL 图
    %
    % 蓝色：全部 DNL
    % 红色：missing_codes
    % 橙色：wide_codes
    %% -----------------------------------------------------
    nexttile;
    stem(0:n_codes-1, DNL, 'b', 'LineWidth', 1.8, 'MarkerSize', 7);
    hold on;

    if ~isempty(missing_codes)
        idx_red = missing_codes + 1;
        stem(missing_codes, DNL(idx_red), 'ro', 'LineWidth', 2.5, 'MarkerSize', 9);
    end

    if ~isempty(wide_codes)
        idx_orange = wide_codes + 1;
        stem(wide_codes, DNL(idx_orange), 'Color', [.9 .5 0], ...
            'LineWidth', 2.5, 'MarkerSize', 9);
    end

    hold off;
    grid on; box on;
    xlabel('Code');
    ylabel('DNL (LSB)');
    title('DNL (Red = Missing, Orange = Wide Code)');

    if ~isempty(DNL_valid)
        y_low  = min(DNL_valid);
        y_high = max(DNL_valid);

        if abs(y_low - y_high) < 1e-12
            y_low  = y_low  - 0.1;
            y_high = y_high + 0.1;
        end

        margin = 0.15 * max(abs([y_low, y_high]));
        if margin < 0.2
            margin = 0.2;
        end
        ylim([y_low - margin, y_high + margin]);
    end

    %% -----------------------------------------------------
    % 5.9 INL 图
    %% -----------------------------------------------------
    nexttile;
    stem(0:n_codes-1, INL, 'r', 'LineWidth', 1.8, 'MarkerSize', 7);
    grid on; box on;
    xlabel('Code');
    ylabel('INL (LSB)');
    title('INL');

    if ~isempty(INL_valid)
        maxi = max(abs(INL_valid));
        if maxi == 0
            maxi = 0.1;
        end
        ylim([-1.2 * maxi, 1.2 * maxi]);
    end

    %% -----------------------------------------------------
    % 5.10 动态时域图
    %% -----------------------------------------------------
    nexttile;
    hold on;
    N_show = 2 * min(round(N_DYNAMIC / ramp_periods), length(t_dyn));
    plot(t_dyn(1:N_show), v_in_dyn(1:N_show), 'b-', 'LineWidth', 1.5);
    stairs(t_dyn(1:N_show), v_out_dyn(1:N_show), 'r-', 'LineWidth', 1.5);
    hold off;
    grid on; box on;
    xlabel('Time (s)');
    ylabel('v_{in} / v_{out}');
    legend('Input', 'Output', 'Location', 'best');
    ylim([-v_ref - 0.5, v_ref + 0.5]);
    title('Time Domain Waveform');

end

elapsed_time = toc;
disp(['总耗时 = ', num2str(elapsed_time), ' s']);

