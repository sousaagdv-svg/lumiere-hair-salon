-- ==============================================================================
-- MIGRAÇÃO 002: RPC horarios_livres E LÓGICA DE DISPONIBILIDADE
-- ==============================================================================

-- Função PostgreSQL para calcular horários disponíveis considerando fuso horário,
-- duração do serviço, expediente do salão e exclusão de conflitos de agendamento.
CREATE OR REPLACE FUNCTION public.horarios_livres(
    p_profissional_id UUID,
    p_data DATE,
    p_duracao INT
)
RETURNS TABLE (
    inicio TIMESTAMPTZ,
    fim TIMESTAMPTZ,
    horario TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_dia_semana INT;
    v_abre TIME;
    v_fecha TIME;
    v_is_aberto BOOLEAN;
    v_slot_inicio TIME;
    v_slot_fim TIME;
    v_slot_inicio_ts TIMESTAMPTZ;
    v_slot_fim_ts TIMESTAMPTZ;
    v_tz TEXT := 'America/Sao_Paulo';
    v_prof_real_id UUID;
    v_profs_ativos UUID[];
BEGIN
    -- 1. Determinar o dia da semana (0 = Domingo, 1 = Segunda, ..., 6 = Sábado)
    v_dia_semana := EXTRACT(DOW FROM (p_data AT TIME ZONE v_tz));

    -- 2. Consultar se o estabelecimento está aberto neste dia da semana
    SELECT abre, fecha, ativo INTO v_abre, v_fecha, v_is_aberto
    FROM public.horarios_funcionamento
    WHERE dia_semana = v_dia_semana;

    -- Se não houver expediente ou estiver fechado, retorna vazio
    IF v_is_aberto IS NOT TRUE OR v_abre IS NULL OR v_fecha IS NULL THEN
        RETURN;
    END IF;

    -- 3. Tratar a opção "Sem preferência"
    SELECT id INTO v_prof_real_id FROM public.profissionais WHERE nome = 'Sem preferência' AND id = p_profissional_id;
    
    IF v_prof_real_id IS NOT NULL THEN
        SELECT ARRAY_AGG(id) INTO v_profs_ativos 
        FROM public.profissionais 
        WHERE ativo = true AND nome <> 'Sem preferência';
        
        IF v_profs_ativos IS NULL OR ARRAY_LENGTH(v_profs_ativos, 1) = 0 THEN
            RETURN;
        END IF;
    else
        v_profs_ativos := ARRAY[p_profissional_id];
    END IF;

    -- 4. Gerar slots de 30 em 30 minutos dentro do horário de funcionamento
    v_slot_inicio := v_abre;
    
    WHILE v_slot_inicio + (p_duracao || ' minutes')::INTERVAL <= v_fecha LOOP
        v_slot_fim := v_slot_inicio + (p_duracao || ' minutes')::INTERVAL;

        -- Construir Timestamptz considerando o fuso horário America/Sao_Paulo
        v_slot_inicio_ts := (p_data || ' ' || v_slot_inicio)::TIMESTAMP AT TIME ZONE v_tz;
        v_slot_fim_ts := (p_data || ' ' || v_slot_fim)::TIMESTAMP AT TIME ZONE v_tz;

        -- Verificar disponibilidade para os profissionais elegíveis
        IF EXISTS (
            SELECT 1 
            FROM public.profissionais pr
            WHERE pr.id = ANY(v_profs_ativos)
              AND pr.ativo = true
              AND NOT EXISTS (
                  SELECT 1 
                  FROM public.agendamentos a
                  WHERE a.profissional_id = pr.id
                    AND a.status <> 'cancelado'
                    AND tstzrange(a.inicio, a.fim) && tstzrange(v_slot_inicio_ts, v_slot_fim_ts)
              )
        ) THEN
            inicio := v_slot_inicio_ts;
            fim := v_slot_fim_ts;
            horario := TO_CHAR(v_slot_inicio, 'HH24:MI');
            RETURN NEXT;
        END IF;

        v_slot_inicio := v_slot_inicio + INTERVAL '30 minutes';
    END LOOP;

    RETURN;
END;
$$;
