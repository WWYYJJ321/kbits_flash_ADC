%% ========================================================================
% 局部函数：
% 直接基于每个 code 在静态 ramp 上“实际占据的输入区间”计算 DNL / INL
%
% 优点：
% 1) 不再依赖“先提阈值再算码宽”
% 2) 和左侧传输曲线严格一致
% 3) 某码未出现时，直接 width = 0 -> DNL = -1
% 4) 对 1/2/3/4 模式都更稳
%% ========================================================================
%% 函数定义：输入输出参数说明
% 输入：
%   v_in      : ADC输入的斜坡电压序列（模拟输入）
%   code      : ADC输出的数字码序列（与v_in一一对应）
%   v_ref     : ADC参考电压的单极性幅值，总输入范围 [-v_ref, +v_ref]
%   n_codes   : ADC总输出码数（例如12位ADC：n_codes=4096）
% 输出：
%   DNL         : 微分非线性数组（单位：LSB），长度=n_codes
%   INL         : 积分非线性数组（单位：LSB），长度=n_codes
%   missing_codes: 失码列表（没有输出过的数字码）
%   wide_codes  : 超宽码列表（DNL>1LSB的异常码）
%   code_widths : 每个数字码实际占据的模拟电压宽度
function [DNL, INL, missing_codes, wide_codes, code_widths] = ...
    calc_dnl_inl_from_static_ramp(v_in, code, v_ref, n_codes)

    % 计算理想情况下1个LSB对应的模拟电压值
    % 总输入范围：2*v_ref，总码数n_codes → 理想1LSB宽度
    delta = 2 * v_ref / n_codes;   

    %% 1) 数据合法化处理：保证输出码在有效范围内
    % 对输出码四舍五入（防止浮点型误差）
    code = round(code);
    % 限制码值范围：最小0，最大 n_codes-1（标准ADC码范围）
    code = min(max(code, 0), n_codes - 1);

    %% 2) 按输入电压从小到大排序
    % 将输入电压展成列向量并排序，返回排序后的值+原始索引
    [v_sorted, idx] = sort(v_in(:));
    % 数字码按照输入电压的排序结果重新排列，保证电压和码一一对应
    code_sorted = code(idx);

    %% 3) 逐码计算实际占据的模拟电压宽度（核心步骤）
    % 初始化所有码的宽度为0
    code_widths = zeros(1, n_codes);

    % 遍历ADC所有输出码 0 ~ n_codes-1
    for c = 0:n_codes-1
        % 找到排序后所有等于当前码c的位置索引
        pos = find(code_sorted == c);   % 找出所有输出为 c 的位置

        if isempty(pos)                 % 判断：当前码没有出现过 → 失码，宽度直接设为0
            code_widths(c+1) = 0;       % 没找到 → 失码 → 宽度=0
        else
            % 当前码出现过：取第一次出现和最后一次出现的位置
            i_first = pos(1);
            i_last  = pos(end);

            % ===================== 计算左边界电压 =====================
            if i_first == 1
                % 该码是排序后的第一个点 → 左边界为最小输入电压 -v_ref
                v_left = -v_ref;
            else
                % 正常情况：左边界 = (当前码第一个点 + 前一个点的电压)的中点
                % 中点法：两个相邻码的分界点
                v_left = (v_sorted(i_first-1) + v_sorted(i_first)) / 2;
            end

            % ===================== 计算右边界电压 =====================
            if i_last == length(v_sorted)
                % 该码是排序后的最后一个点 → 右边界为最大输入电压 +v_ref
                v_right = v_ref;
            else
                % 正常情况：右边界 = (当前码最后一个点 + 后一个点的电压)的中点
                v_right = (v_sorted(i_last) + v_sorted(i_last+1)) / 2;
            end

            % 码宽度 = 右边界 - 左边界，保证非负
            code_widths(c+1) = max(0, v_right - v_left);
        end
    end

    %% 4) 检测失码：码宽度=0 表示该数字码从未输出过
    % find返回数组下标，-1还原为真实码值（数组下标1→码0）
    %%%%%%%%%%%%%%%%%%%超级直观小例子%%%%%%%%%%%%%%%%%%%%%%%%%% 
    % % % % % % % % 假设：3 位 ADC，共 8 个码（0~7）code_widths = [1, 1, 0, 1, 0, 1, 1, 1]
    % % % % % % % % missing_codes = find(code_widths == 0) - 1;
    % % % % % % % % 步骤：
    % % % % % % % % code_widths == 0 → 第 3、5 位是 0
    % % % % % % % % find(...) → 返回 [3,5]
    % % % % % % % % -1 → 得到 真实失码：[2,4]
    % % % % % % % % 结果：missing_codes = [2, 4]
    % % % % % % % % 表示 ADC 从未输出过码 2 和 4。
    missing_codes = find(code_widths == 0) - 1;

    %% 5) 计算微分非线性 DNL
    % DNL公式：(实际码宽 / 理想LSB宽度) - 1  （单位：LSB）
    DNL = code_widths / delta - 1;

    % 强制修正：失码的DNL严格等于 -1 LSB（行业标准定义）
    if ~isempty(missing_codes)
        DNL(missing_codes + 1) = -1;
    end

    %% 6) 计算积分非线性 INL
    % INL定义：从第一个码开始，DNL的累加和（累计误差）
    INL = zeros(1, n_codes);
    % 从第2个码开始累加（第0个码INL=0）
    for k = 2:n_codes
        INL(k) = INL(k-1) + DNL(k-1);
    end

    %% 7) 检测超宽码：DNL > 1LSB 定义为宽码（异常码）
    wide_codes = find(DNL > 1) - 1;
end


