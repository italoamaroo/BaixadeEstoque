"""Teste ponta a ponta da fase 3: incidente aberto a partir de alerta, prazos, encerramento e configuração LGPD."""
import os
import re
from datetime import datetime
from playwright.sync_api import sync_playwright, expect

BASE = os.environ.get('E2E_BASE', 'http://localhost:5173')
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
os.makedirs(OUT, exist_ok=True)


def login(page, email, password='teste123', ok=True):
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill(email)
    page.get_by_label('Senha').fill(password)
    page.get_by_role('button', name='Entrar').click()
    if ok:
        page.wait_for_url(re.compile(r'.*/$'), timeout=15000)


with sync_playwright() as p:
    browser = p.chromium.launch()

    # 5 falhas de login -> alerta
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    f = ctx.new_page()
    for _ in range(5):
        login(f, 'gestor@teste.local', 'errada', ok=False)
        expect(f.get_by_text(re.compile('E-mail ou senha incorretos'))).to_be_visible(timeout=10000)
    ctx.close()

    ctx = browser.new_context(viewport={'width': 1366, 'height': 1100})
    a = ctx.new_page()
    login(a, 'admin@teste.local')

    # Alerta -> Registrar incidente (já vem com o alerta e o título)
    a.goto(f'{BASE}/admin/seguranca')
    a.locator('li').filter(has_text=re.compile('falhas de login', re.I)).first.get_by_role('link', name='Registrar incidente').click()
    dlg = a.get_by_role('dialog')
    expect(dlg.get_by_label('Título')).to_have_value(re.compile('falhas de login', re.I), timeout=15000)
    dlg.get_by_label('Título').fill('Tentativas de acesso à conta do gestor')
    dlg.get_by_role('button', name='Registrar').click()
    expect(a.get_by_text('Incidente registrado.')).to_be_visible(timeout=10000)
    expect(a.get_by_text(re.compile(r'INC-\d{4}-001'))).to_be_visible()
    expect(a.get_by_text(re.compile('Informe quando se soube'))).to_be_visible()
    expect(a.get_by_text('Configuração LGPD a definir')).to_be_visible()

    # Conhecimento de dados pessoais -> prazos aparecem
    now = datetime.now().strftime('%Y-%m-%dT%H:%M')
    a.get_by_label('Soube que afetou dados pessoais').fill(now)
    a.get_by_role('button', name='Salvar alterações').click()
    expect(a.get_by_text('Incidente salvo.')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Comunicação à ANPD (art. 6º)')).to_be_visible()
    expect(a.get_by_text(re.compile(r'pendente · 3 dias úteis')).first).to_be_visible()
    a.screenshot(path=f'{OUT}/i01_incidente_prazos.png', full_page=True)

    # Encerrar sem os campos obrigatórios -> recusa explicando o que falta
    a.get_by_role('button', name='Encerrar incidente').click()
    a.get_by_role('dialog').get_by_label('Resumo do encerramento').fill('Encerrando teste automatizado')
    a.get_by_role('dialog').get_by_role('button', name='Encerrar').click()
    expect(a.get_by_text(re.compile('Para encerrar, preencha: descrição'))).to_be_visible(timeout=10000)
    a.get_by_role('dialog').get_by_role('button', name='Voltar').click()

    # Preenche art. 10 e conclui sem risco relevante
    a.get_by_label('Descrição geral de como o incidente ocorreu').fill('5 senhas erradas seguidas; o próprio gestor esqueceu a senha')
    a.get_by_label('Categorias (separe por vírgula)').fill('e-mail, senha')
    a.get_by_label('Número de titulares').fill('1')
    a.get_by_label(re.compile('Dados de autenticação em sistemas')).check()
    a.get_by_label('Conclusão').select_option('sem_risco_relevante')
    a.get_by_label('Avaliação do risco e possíveis danos aos titulares').fill('Sem acesso indevido: o titular confirmou as tentativas')
    a.get_by_label('Por que não foi comunicado').fill('Sem risco ou dano relevante: tentativas do próprio titular')
    a.get_by_role('button', name='Salvar alterações').click()
    expect(a.get_by_text('Incidente salvo.').last).to_be_visible(timeout=10000)
    expect(a.get_by_text(re.compile('sem risco ou dano relevante: comunicação não obrigatória', re.I))).to_be_visible()
    a.get_by_role('button', name='Encerrar incidente').click()
    a.get_by_role('dialog').get_by_label('Resumo do encerramento').fill('Senha redefinida pelo próprio gestor')
    a.get_by_role('dialog').get_by_role('button', name='Encerrar').click()
    expect(a.get_by_text('Incidente encerrado.')).to_be_visible(timeout=10000)
    expect(a.get_by_role('button', name='Salvar alterações')).to_have_count(0)
    a.get_by_label('Nova anotação').fill('Revisado na reunião mensal')
    a.get_by_role('button', name='Anotar').click()
    expect(a.get_by_text('Revisado na reunião mensal')).to_be_visible(timeout=10000)
    a.screenshot(path=f'{OUT}/i02_incidente_encerrado.png', full_page=True)

    # Configuração: porte e feriado municipal
    a.get_by_role('tab', name=re.compile('Configuração LGPD')).click()
    a.get_by_label(re.compile('Agente de pequeno porte')).select_option('nao')
    a.get_by_role('button', name='Salvar', exact=True).click()
    expect(a.get_by_text('Configuração salva.')).to_be_visible(timeout=10000)
    a.get_by_label('Data').fill('2026-12-08')
    a.get_by_label('Nome').fill('Nossa Senhora da Conceição (Recife)')
    a.get_by_role('button', name='Cadastrar feriado').click()
    expect(a.get_by_text('Nossa Senhora da Conceição (Recife)')).to_be_visible(timeout=10000)
    a.screenshot(path=f'{OUT}/i03_config_lgpd.png', full_page=True)

    # Trilha: eventos de incidente na auditoria
    a.goto(f'{BASE}/admin/auditoria')
    a.get_by_label('Categoria').select_option('incidente')
    a.get_by_role('button', name='Buscar').click()
    expect(a.locator('ul li').get_by_text('Incidente encerrado').first).to_be_visible(timeout=15000)
    expect(a.locator('ul li').get_by_text('Incidente registrado').first).to_be_visible()
    ctx.close()

    # Gestor não vê incidentes
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1000})
    g = ctx.new_page()
    login(g, 'gestor@teste.local')
    assert g.get_by_role('link', name='Incidentes').count() == 0
    g.goto(f'{BASE}/admin/incidentes')
    expect(g.get_by_text('Incidentes de segurança')).to_have_count(0)
    ctx.close()
    print('OK')
    browser.close()
