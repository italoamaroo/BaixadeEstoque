"""Teste ponta a ponta da fase 4: pedido de titular, relatório, resposta e cópia offline (minimização, validade, limpeza ao sair)."""
import os
import re
from playwright.sync_api import sync_playwright, expect

BASE = os.environ.get('E2E_BASE', 'http://localhost:5173')
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
os.makedirs(OUT, exist_ok=True)

IDB_DUMP = """async () => {
  const db = await new Promise((res, rej) => { const r = indexedDB.open('baixas-estoque-offline'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
  const get = (store, fn) => new Promise((res) => { const t = db.transaction(store, 'readonly'); const q = fn(t.objectStore(store)); q.onsuccess = () => res(q.result); });
  const keys = await get('kv', (s) => s.getAllKeys());
  const emps = await get('kv', (s) => s.get('cache:employees'));
  return { keys, emp: emps && emps[0] ? Object.keys(emps[0]).filter((k) => emps[0][k] !== null && emps[0][k] !== true).sort() : null };
}"""
AGE_CACHE = """async () => {
  const db = await new Promise((res) => { const r = indexedDB.open('baixas-estoque-offline'); r.onsuccess = () => res(r.result); });
  const t = db.transaction('kv', 'readwrite'); const s = t.objectStore('kv');
  await new Promise((res) => { const q = s.get('cache:info'); q.onsuccess = () => { const v = q.result; v.updated_at = new Date(Date.now() - 8 * 864e5).toISOString(); s.put(v, 'cache:info').onsuccess = res; }; });
}"""


def login(page, email):
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill(email)
    page.get_by_label('Senha').fill('teste123')
    page.get_by_role('button', name='Entrar').click()
    page.wait_for_url(re.compile(r'.*/$'), timeout=15000)


with sync_playwright() as p:
    browser = p.chromium.launch()

    # ---------------- Pedido de titular (administrador)
    ctx = browser.new_context(viewport={'width': 1366, 'height': 1100}, accept_downloads=True)
    a = ctx.new_page()
    login(a, 'admin@teste.local')
    a.get_by_role('link', name='Pedidos de titulares').click()
    expect(a.get_by_text('Canal de atendimento a definir')).to_be_visible(timeout=15000)

    a.get_by_role('button', name='Registrar pedido').click()
    dlg = a.get_by_role('dialog')
    dlg.get_by_label(re.compile('Pesquisar funcionário')).fill('DEMO-1001')
    dlg.get_by_role('button', name=re.compile('José Carlos da Silva')).click()
    expect(dlg.get_by_label('Nome de quem pediu')).to_have_value('José Carlos da Silva')
    expect(dlg.get_by_role('button', name='Registrar')).to_be_disabled()
    dlg.get_by_label(re.compile(r'Acesso aos dados \(II\)')).check()
    dlg.get_by_label('Canal').fill('Presencial no RH')
    dlg.get_by_role('button', name='Registrar').click()
    expect(a.get_by_text('Pedido registrado.')).to_be_visible(timeout=10000)
    expect(a.get_by_text(re.compile(r'SOL-\d{4}-001'))).to_be_visible()
    expect(a.get_by_text(re.compile(r'no prazo, 15 dias'))).to_be_visible()

    # Relatório do titular (Excel)
    a.get_by_role('button', name='Gerar relatório').click()
    expect(a.get_by_text(re.compile(r'retirada\(s\) registrada\(s\)'))).to_be_visible(timeout=10000)
    with a.expect_download() as d:
        a.get_by_role('button', name='Baixar relatório (Excel)').click()
    assert d.value.suggested_filename.startswith('dados-do-titular-DEMO-1001'), d.value.suggested_filename

    # Resposta sem identidade conferida: recusada
    a.get_by_role('button', name='Registrar resposta').click()
    dlg = a.get_by_role('dialog')
    expect(dlg.get_by_text(re.compile('identidade ainda não foi conferida'))).to_be_visible()
    dlg.get_by_label('Resumo da resposta dada').fill('Relatório entregue em mãos ao titular')
    dlg.get_by_role('button', name='Registrar').click()
    expect(a.get_by_text(re.compile('Confira e registre a identidade'))).to_be_visible(timeout=10000)
    dlg.get_by_role('button', name='Voltar').click()

    a.get_by_label('Identidade conferida').check()
    a.get_by_label('Como a identidade foi conferida').fill('Crachá conferido pelo RH')
    a.get_by_role('button', name='Salvar', exact=True).click()
    expect(a.get_by_text('Pedido salvo.')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Em análise').first).to_be_visible()
    a.get_by_role('button', name='Registrar resposta').click()
    dlg = a.get_by_role('dialog')
    dlg.get_by_label('Resumo da resposta dada').fill('Relatório entregue em mãos ao titular')
    dlg.get_by_role('button', name='Registrar').click()
    expect(a.get_by_text('Resposta registrada.')).to_be_visible(timeout=10000)
    expect(a.get_by_text(re.compile('Atendido em'))).to_be_visible()
    a.screenshot(path=f'{OUT}/t01_pedido_titular.png', full_page=True)

    # Canal definido
    a.get_by_role('button', name='← Voltar à lista').click()
    a.get_by_role('button', name='Canal e prazo').click()
    dlg = a.get_by_role('dialog')
    dlg.get_by_label('Canal para os pedidos').fill('privacidade@empresa.com.br')
    dlg.get_by_role('button', name='Salvar').click()
    expect(a.get_by_text('Canal e prazo salvos.')).to_be_visible(timeout=10000)
    expect(a.get_by_text('Canal de atendimento a definir')).to_have_count(0)

    # Trilha sem o nome do titular
    a.goto(f'{BASE}/admin/auditoria')
    a.get_by_label('Categoria').select_option('privacidade')
    a.get_by_role('button', name='Buscar').click()
    expect(a.locator('ul li').get_by_text('Pedido de titular respondido').first).to_be_visible(timeout=15000)
    expect(a.locator('ul li').get_by_text('Relatório de dados do titular gerado').first).to_be_visible()
    assert 'José Carlos' not in a.locator('main ul').inner_text()
    ctx.close()

    # ---------------- Cópia offline no tablet (almoxarife)
    ctx = browser.new_context(viewport={'width': 1280, 'height': 900})
    m = ctx.new_page()
    login(m, 'almox.mur@teste.local')
    m.goto(f'{BASE}/saidas-offline')
    m.get_by_role('button', name='Atualizar agora').click()
    expect(m.get_by_text(re.compile(r'só nome e matrícula'))).to_be_visible(timeout=20000)
    expect(m.get_by_text(re.compile(r'Vale até'))).to_be_visible()
    dump = m.evaluate(IDB_DUMP)
    assert dump['emp'] == ['full_name', 'id', 'registration'], dump
    assert 'cache:materials' in dump['keys'], dump

    # Cópia com mais de 7 dias: apagada e não usada
    # (sem internet, para a atualização automática não refazer a cópia na hora)
    # (no servidor de desenvolvimento a tela precisa ter sido carregada antes de cortar a rede)
    m.get_by_role('link', name='Painel').first.click()
    m.wait_for_url(re.compile(r'.*/$'), timeout=15000)
    m.wait_for_timeout(1000)
    m.evaluate(AGE_CACHE)
    ctx.set_offline(True)
    m.get_by_role('link', name='Saídas offline').click()
    expect(m.get_by_text(re.compile('Ainda não há cópia neste aparelho'))).to_be_visible(timeout=15000)
    stale = lambda d: [k for k in d['keys'] if k in ('cache:materials', 'cache:employees', 'cache:info') or str(k).startswith('cache:lookup:')]
    for _ in range(20):
        dump = m.evaluate(IDB_DUMP)
        if not stale(dump):
            break
        m.wait_for_timeout(250)
    assert not stale(dump), dump
    ctx.set_offline(False)
    m.wait_for_timeout(1000)

    # Ao sair do sistema, nada de "cache:" fica no aparelho
    m.get_by_role('button', name='Atualizar agora').click()
    expect(m.get_by_text(re.compile(r'só nome e matrícula'))).to_be_visible(timeout=20000)
    m.get_by_role('button', name='Menu do usuário').click()
    m.get_by_role('button', name='Sair').click()
    m.wait_for_url(re.compile(r'.*/login$'), timeout=15000)
    for _ in range(20):
        dump = m.evaluate(IDB_DUMP)
        if not [k for k in dump['keys'] if str(k).startswith('cache:')]:
            break
        m.wait_for_timeout(250)
    assert not [k for k in dump['keys'] if str(k).startswith('cache:')], dump
    ctx.close()
    print('OK')
    browser.close()
