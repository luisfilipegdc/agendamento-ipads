-- =============================================================================
-- Escolha de unidade no primeiro acesso.
--
-- As três unidades compartilham o mesmo domínio de e-mail, então o domínio não
-- diz a qual unidade o professor pertence. Sem unidade, minhas_unidades() volta
-- vazio e o RLS recusa qualquer reserva — sem explicação útil na tela.
--
-- O professor passa a escolher a unidade no primeiro acesso; a coordenação pode
-- corrigir depois.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CORREÇÃO: o provisionamento quebrava para domínio compartilhado.
--
-- pessoa_papel tem unidade_id na chave primária, logo NOT NULL. Com um domínio
-- sem unidade (o caso real: as três unidades dividem o mesmo e-mail), o gatilho
-- tentava inserir o papel com unidade nula e a criação do usuário falhava por
-- inteiro — ninguém conseguia sequer entrar.
--
-- Agora o papel só é criado quando o domínio aponta uma unidade. Quem vem de
-- domínio compartilhado recebe o papel ao escolher a unidade, no primeiro
-- acesso.
-- -----------------------------------------------------------------------------
create or replace function provisiona_pessoa()
returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_dom  dominio_permitido%rowtype;
  v_nome text;
begin
  select * into v_dom from dominio_permitido
   where dominio = lower(split_part(new.email, '@', 2));

  if not found then
    raise exception 'Domínio de e-mail não autorizado: %',
      split_part(new.email, '@', 2);
  end if;

  v_nome := coalesce(new.raw_user_meta_data->>'full_name',
                     new.raw_user_meta_data->>'name',
                     initcap(replace(split_part(new.email, '@', 1), '.', ' ')));

  insert into pessoa (id, nome, email, unidade_id)
  values (new.id, v_nome, lower(new.email), v_dom.unidade_id)
  on conflict (id) do nothing;

  -- Só concede o papel quando há unidade. Sem isto, um domínio compartilhado
  -- entre unidades derruba a criação do usuário.
  if v_dom.unidade_id is not null then
    insert into pessoa_papel (pessoa_id, papel, unidade_id)
    values (new.id, v_dom.papel_padrao, v_dom.unidade_id)
    on conflict do nothing;
  end if;

  return new;
end;
$$;

-- Lista das unidades para a tela de escolha. Precisa funcionar para quem ainda
-- não tem unidade, então não depende de minhas_unidades().
create or replace function unidades_disponiveis()
returns table (id uuid, nome text, sigla text)
language sql stable security definer set search_path = public as $$
  select u.id, u.nome, u.sigla
    from unidade u
   where u.ativo
   order by u.nome;
$$;

-- O próprio usuário define sua unidade. Só entre as ativas, e o papel
-- acompanha: uma linha de pessoa_papel apontando para outra unidade daria
-- acesso indevido àquela unidade.
create or replace function define_minha_unidade(p_unidade uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_existe boolean;
begin
  if auth.uid() is null then
    raise exception 'Sessão inválida.';
  end if;

  select exists (select 1 from unidade where id = p_unidade and ativo)
    into v_existe;
  if not v_existe then
    raise exception 'Unidade inexistente ou inativa.';
  end if;

  update pessoa set unidade_id = p_unidade where id = auth.uid();

  -- Move os papéis sem unidade, e os que apontavam para outra unidade, para a
  -- escolhida. ADMIN é global e não se move.
  update pessoa_papel
     set unidade_id = p_unidade
   where pessoa_id = auth.uid()
     and papel <> 'ADMIN'
     and unidade_id is distinct from p_unidade;

  -- Garante ao menos o papel de professor.
  insert into pessoa_papel (pessoa_id, papel, unidade_id)
  values (auth.uid(), 'PROFESSOR', p_unidade)
  on conflict do nothing;
end $$;

comment on function define_minha_unidade is
  'Primeiro acesso: o professor escolhe a unidade. A coordenação pode corrigir '
  'depois pela gestão de pessoas.';

-- Perfil do usuário logado, para a tela decidir o que mostrar.
create or replace function meu_perfil()
returns table (
  id uuid, nome text, email text, unidade_id uuid, unidade_nome text,
  papeis papel[], precisa_escolher_unidade boolean
)
language sql stable security definer set search_path = public as $$
  select p.id, p.nome, p.email, p.unidade_id, u.nome,
         coalesce(array_agg(pp.papel) filter (where pp.papel is not null),
                  '{}'::papel[]),
         -- ADMIN alcança todas as unidades; não precisa escolher.
         p.unidade_id is null
           and not exists (select 1 from pessoa_papel a
                            where a.pessoa_id = p.id and a.papel = 'ADMIN')
    from pessoa p
    left join unidade u on u.id = p.unidade_id
    left join pessoa_papel pp on pp.pessoa_id = p.id
   where p.id = auth.uid()
   group by p.id, p.nome, p.email, p.unidade_id, u.nome;
$$;
