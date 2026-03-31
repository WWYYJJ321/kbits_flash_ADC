function [code, v_out, comp_out, th_actual] = kbits_flash_adc_leftrise_offset( ...
    vin, v_ref, k_bits, vos_arr, offset_selection, vos_sigma)
% kbits_flash_adc_leftrise_offset
%
% 功能：
%   k-bit Flash ADC 单次转换函数（支持 4 种模式）
%
% 输入：
%   vin              - 输入电压（标量）
%   v_ref            - 满量程一半，输入范围 [-v_ref, v_ref]
%   k_bits           - ADC 位数
%   vos_arr          - 比较器失调数组，长度 = 2^k_bits - 1
%   offset_selection - 模式选择
%                      1: Independent Offset
%                      2: Correlated Offset
%                      3: Metastability
%                      4: Correlated Offset + Metastability
%   vos_sigma        - 失调/亚稳态强度参数
%
% 输出：
%   code      - 输出码（0 ~ 2^k_bits-1）
%   v_out     - 量化输出电压
%   comp_out  - thermometer code
%   th_actual - 实际比较器阈值
%
% 说明：
%   1) mode 1/2/4 的 offset 由外部 vos_arr 提供
%   2) mode 3 不使用静态失调，阈值使用理想值
%   3) mode 3/4 在阈值附近引入亚稳态随机判决
%   4) 该函数只做“单次转换”，DNL/INL 统计放在 testbench 中

    %% 1) 基本参数
    n_codes = 2^k_bits;       % 总输出码数
    n_comp  = n_codes - 1;    % 比较器数量（ADC 内部阈值个数）
    delta   = 2 * v_ref / n_codes; % 理想 1 LSB 电压宽度
    
    if ~isscalar(vin)
        error('vin 必须是标量。');
    end
    
    if length(vos_arr) ~= n_comp
        error('vos_arr 长度必须为 2^k_bits - 1。');
    end

    % 理想阈值：-v_ref + delta, ..., v_ref - delta
    th_ideal = -v_ref + delta * (1:n_comp);

  %% 2) 实际阈值
    switch offset_selection
        case {1, 2, 4}
            % 这些模式使用外部给定的静态失调
            th_actual = th_ideal + vos_arr;
    
        case 3
            % Mode 3: 只有亚稳态，不引入静态阈值偏移
            th_actual = th_ideal;
    
        otherwise
            error('offset_selection 只能取 1、2、3、4。');
    end
    %% 3) 比较器判决
    comp_out = zeros(1, n_comp);

    % 亚稳态窗口，和 LSB、vos_sigma 相关
    % 用比较器噪声强度 × LSB 大小 → 计算出亚稳态窗口的理论宽度
    % 但亚稳态窗口不能等于 0（会导致除法错误、边界判断死循环、数值奇异）
    % 所以用 max 强制保底为 1e-12（1 皮秒级电压，极小但安全）
    meta_window = max(1e-12, abs(vos_sigma) * delta); 
    
    % 遍历所有比较器（n_comp = 2^bits - 1 个）
    for i = 1:n_comp
        % 计算：输入电压 vin - 第i个比较器的实际阈值
        % d > 0  → 输入电压 > 阈值 → 理论应输出 1
        % d < 0  → 输入电压 < 阈值 → 理论应输出 0
        d = vin - th_actual(i);
    
        % ===================== 模式判断：是否开启亚稳态 =====================
        if ismember(offset_selection, [3, 4])
            % ===================== 【模式3、4：含亚稳态】 =====================
            % 判断输入电压距离阈值是否【超出亚稳态窗口】
            if abs(d) > meta_window
                % 远离阈值：比较器输出稳定，直接判决
                % d >= 0 → 输出1；否则输出0；转成双精度浮点
                comp_out(i) = double(d >= 0);
            else
                % ===================== 核心：亚稳态概率判决 =====================
                % 输入电压在阈值附近的小窗口内 → 输出随机、不确定
                % 计算输出为 1 的概率 p_one（0~1之间）
                % 线性概率模型：距离阈值越近，不确定性越强
                p_one = (d + meta_window) / (2 * meta_window);
                % 强制把概率钳位在 0~1 之间，防止越界
                p_one = min(max(p_one, 0), 1);
                % 随机判决：rand 生成0~1随机数 < p_one → 输出1
                comp_out(i) = double(rand < p_one);
            end
        else
            % ===================== 【模式1、2：理想模式，无亚稳态】 =====================
            % 理想比较器：无延迟、无亚稳态，直接硬判决
            comp_out(i) = double(d >= 0);
        end
    end

    %% 4) thermometer -> binary
    code = sum(comp_out);
    code = round(code);
    code = min(max(code, 0), n_codes - 1);

    %% 5) 输出电压
    v_out = -v_ref + code * delta;
end
