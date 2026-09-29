-- ==============================================================================
-- MIGRAÇÃO 001: INFRAESTRUTURA INICIAL DO SISTEMA DE AGENDAMENTO LUMIÈRE
-- ==============================================================================

-- 1. Habilitar extensão btree_gist para suporte a exclusion constraint com GiST
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 2. Tabela de SERVIÇOS
CREATE TABLE IF NOT EXISTS public.servicos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome VARCHAR(100) NOT NULL UNIQUE,
    duracao_min INT NOT NULL CHECK (duracao_min > 0),
    preco NUMERIC(10,2) NOT NULL CHECK (preco >= 0),
    ativo BOOLEAN NOT NULL DEFAULT true,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. Tabela de PROFISSIONAIS
CREATE TABLE IF NOT EXISTS public.profissionais (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    nome VARCHAR(100) NOT NULL UNIQUE,
    foto TEXT,
    ativo BOOLEAN NOT NULL DEFAULT true,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. Tabela de HORÁRIOS DE FUNCIONAMENTO
-- dia_semana: 0 = Domingo, 1 = Segunda, 2 = Terça, 3 = Quarta, 4 = Quinta, 5 = Sexta, 6 = Sábado
CREATE TABLE IF NOT EXISTS public.horarios_funcionamento (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dia_semana INT NOT NULL UNIQUE CHECK (dia_semana BETWEEN 0 AND 6),
    abre TIME NOT NULL,
    fecha TIME NOT NULL CHECK (fecha > abre),
    ativo BOOLEAN NOT NULL DEFAULT true
);

-- 5. Tabela de AGENDAMENTOS
CREATE TABLE IF NOT EXISTS public.agendamentos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    servico_id UUID NOT NULL REFERENCES public.servicos(id) ON DELETE RESTRICT,
    profissional_id UUID NOT NULL REFERENCES public.profissionais(id) ON DELETE RESTRICT,
    inicio TIMESTAMPTZ NOT NULL,
    fim TIMESTAMPTZ NOT NULL CHECK (fim > inicio),
    cliente_nome VARCHAR(150) NOT NULL,
    telefone VARCHAR(20) NOT NULL,
    observacoes TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'confirmado' CHECK (status IN ('confirmado', 'concluido', 'faltou', 'cancelado')),
    user_id UUID,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. EXCLUSION CONSTRAINT: Impede sobreposição de horários ativos para o mesmo profissional no banco de dados
-- Apenas agendamentos que NÃO estejam 'cancelado' entram no cálculo da constraint
ALTER TABLE public.agendamentos 
    DROP CONSTRAINT IF EXISTS agendamentos_no_overlap;

ALTER TABLE public.agendamentos 
    ADD CONSTRAINT agendamentos_no_overlap 
    EXCLUDE USING gist (
        profissional_id WITH =,
        tstzrange(inicio, fim) WITH &&
    ) WHERE (status <> 'cancelado');

-- 7. ÍNDICES DE PERFORMANCE
CREATE INDEX IF NOT EXISTS idx_agendamentos_profissional_data 
    ON public.agendamentos (profissional_id, inicio, fim) 
    WHERE status <> 'cancelado';

CREATE INDEX IF NOT EXISTS idx_agendamentos_status 
    ON public.agendamentos (status);

CREATE INDEX IF NOT EXISTS idx_agendamentos_user_id 
    ON public.agendamentos (user_id) 
    WHERE user_id IS NOT NULL;

-- 8. ROW LEVEL SECURITY (RLS)
ALTER TABLE public.servicos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profissionais ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.horarios_funcionamento ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agendamentos ENABLE ROW LEVEL SECURITY;

-- Políticas de RLS para Leitura Pública de Catálogos (necessário para o formulário de agendamento)
CREATE POLICY "Leitura pública de serviços ativos" 
    ON public.servicos FOR SELECT 
    USING (ativo = true);

CREATE POLICY "Leitura pública de profissionais ativos" 
    ON public.profissionais FOR SELECT 
    USING (ativo = true);

CREATE POLICY "Leitura pública de horários de funcionamento ativos" 
    ON public.horarios_funcionamento FOR SELECT 
    USING (ativo = true);

-- Política de RLS para Criação de Agendamentos (permitir que clientes criem agendamentos)
CREATE POLICY "Inserção pública de agendamentos" 
    ON public.agendamentos FOR INSERT 
    WITH CHECK (true);

-- Leitura de agendamentos restrita ao próprio usuário criador (se autenticado)
CREATE POLICY "Clientes autenticados visualizam seus próprios agendamentos" 
    ON public.agendamentos FOR SELECT 
    USING (auth.uid() IS NOT NULL AND auth.uid() = user_id);

-- 9. DADOS INICIAIS (SEEDING) - Preservando os dados exatos do frontend
INSERT INTO public.servicos (nome, duracao_min, preco, ativo) VALUES
    ('Corte & Style', 60, 180.00, true),
    ('Coloração', 120, 350.00, true),
    ('Tratamentos', 60, 220.00, true),
    ('Extensions', 180, 800.00, true)
ON CONFLICT (nome) DO UPDATE SET 
    duracao_min = EXCLUDED.duracao_min,
    preco = EXCLUDED.preco,
    ativo = EXCLUDED.ativo;

INSERT INTO public.profissionais (nome, foto, ativo) VALUES
    ('Sem preferência', NULL, true),
    ('Ana Clara', NULL, true),
    ('Beatriz', NULL, true),
    ('Camila', NULL, true),
    ('Juliana', NULL, true)
ON CONFLICT (nome) DO UPDATE SET 
    ativo = EXCLUDED.ativo;

-- Horário de Funcionamento: Segunda a Sábado das 09h às 19h (1 = Segunda ... 6 = Sábado)
INSERT INTO public.horarios_funcionamento (dia_semana, abre, fecha, ativo) VALUES
    (1, '09:00:00', '19:00:00', true),
    (2, '09:00:00', '19:00:00', true),
    (3, '09:00:00', '19:00:00', true),
    (4, '09:00:00', '19:00:00', true),
    (5, '09:00:00', '19:00:00', true),
    (6, '09:00:00', '19:00:00', true),
    (0, '09:00:00', '19:00:00', false) -- Domingo fechado
ON CONFLICT (dia_semana) DO UPDATE SET 
    abre = EXCLUDED.abre,
    fecha = EXCLUDED.fecha,
    ativo = EXCLUDED.ativo;
