-- ==============================================================================
-- MIGRAÇÃO 003: ÁREA ADMINISTRATIVA — allowlist + RLS
-- ------------------------------------------------------------------------------
-- Estratégia de segurança
--   O admin NÃO é identificado por senha no frontend nem por claim solta.
--   Existirá uma allowlist explícita (public.admin_users) contendo apenas os
--   auth.users.id autorizados. Toda política do painel exige:
--       auth.uid() IS NOT NULL AND public.is_admin(auth.uid())
--
--   Sem isso, "qualquer usuário autenticado vira admin" — que é exatamente o
--   que não queremos. Qualquer pessoa que crie conta no Supabase Auth por
--   qualquer formulário de signup leria e apagaria a agenda do salão.
-- ==============================================================================

-- ---------------------------------------------------------------------------
-- 1. Função de verificação (SECURITY DEFINER evita recursão de RLS)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin(p_uid UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.admin_users
        WHERE user_id = p_uid
          AND ativo = true
    );
$$;

REVOKE ALL ON FUNCTION public.is_admin(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin(UUID) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Allowlist de administradores
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_users (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    nome VARCHAR(120),
    ativo BOOLEAN NOT NULL DEFAULT true,
    criado_em TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.admin_users IS
    'Allowlist de administradores do painel. Somente estes auth.users.id acessam a agenda.';

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

-- Leitura: um admin logado pode ver a própria allowlist (para exibir "quem sou").
CREATE POLICY "Admin lê a propria allowlist"
    ON public.admin_users FOR SELECT
    TO authenticated
    USING (public.is_admin(auth.uid()));

-- Nenhuma policy de INSERT/UPDATE/DELETE aqui de propósito.
-- Isso significa que a allowlist só pode ser alterada via SQL direto no
-- Supabase Dashboard (ou por service_role no backend). Ninguém consegue se
-- cadastrar como admin pela aplicação.

-- ---------------------------------------------------------------------------
-- 3. RLS da agenda: só admin lê, e só admin altera
-- ---------------------------------------------------------------------------
ALTER TABLE public.agendamentos ENABLE ROW LEVEL SECURITY;

-- Limpa policies anteriores de gestion de agendamentos (Etapa 4/5)
DROP POLICY IF EXISTS "Admins podem gerenciar todos os agendamentos" ON public.agendamentos;
DROP POLICY IF EXISTS "Clientes autenticados visualizam seus próprios agendamentos" ON public.agendamentos;

-- Admin: SELECT
CREATE POLICY "Admin le a agenda"
    ON public.agendamentos FOR SELECT
    TO authenticated
    USING (public.is_admin(auth.uid()));

-- Admin: UPDATE (mudar status, editar observações)
CREATE POLICY "Admin atualiza a agenda"
    ON public.agendamentos FOR UPDATE
    TO authenticated
    USING (public.is_admin(auth.uid()))
    WITH CHECK (public.is_admin(auth.uid()));

-- Sem DELETE: o cancelamento é status='cancelado', nunca remoção de linha.
-- Isso preserva o histórico e mantém a exclusion constraint auditável.

-- Clientes anônimos seguem com INSERT público (fluxo de reserva da Etapa 4).
-- Insert não é afetado pelas policies de SELECT/UPDATE.

-- ---------------------------------------------------------------------------
-- 4. Catálogos: leitura pública de ativos (mantém Etapa 3), escrita só admin
-- ---------------------------------------------------------------------------
ALTER TABLE public.servicos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profissionais ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.horarios_funcionamento ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins podem gerenciar servicos" ON public.servicos;
CREATE POLICY "Admin gerencia servicos"
    ON public.servicos FOR ALL
    TO authenticated
    USING (public.is_admin(auth.uid()))
    WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admins podem gerenciar profissionais" ON public.profissionais;
CREATE POLICY "Admin gerencia profissionais"
    ON public.profissionais FOR ALL
    TO authenticated
    USING (public.is_admin(auth.uid()))
    WITH CHECK (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Admin gerencia horarios" ON public.horarios_funcionamento;
CREATE POLICY "Admin gerencia horarios"
    ON public.horarios_funcionamento FOR ALL
    TO authenticated
    USING (public.is_admin(auth.uid()))
    WITH CHECK (public.is_admin(auth.uid()));

-- ---------------------------------------------------------------------------
-- 5. Índice para a consulta por data (uso principal do painel)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_agendamentos_inicio
    ON public.agendamentos (inicio);

-- Índice parcial para a visão "agenda do dia, ativos"
CREATE INDEX IF NOT EXISTS idx_agendamentos_ativos_por_inicio
    ON public.agendamentos (inicio)
    WHERE status <> 'cancelado';
