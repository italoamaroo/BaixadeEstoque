"""Teste do modo offline: com a versão publicada (service worker), registra uma saída SEM internet,
reabre o app sem internet, guarda no aparelho e confere o envio automático quando a internet volta."""
import os
import re
import subprocess
from playwright.sync_api import sync_playwright, expect

BASE = os.environ.get('E2E_BASE', 'http://localhost:4173')
OUT = os.environ.get('E2E_OUT', 'tests/e2e/capturas')
PSQL = os.environ.get('E2E_PSQL', 'psql -h /tmp -p 54329 -U postgres -d e2e -Atc')
os.makedirs(OUT, exist_ok=True)


def sql(q):
    return subprocess.run(PSQL.split() + [q], capture_output=True, text=True).stdout.strip()


antes = int(sql("select count(*) from stock_movements where entry_channel = 'offline'") or 0)

with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    page = ctx.new_page()

    # Com internet: login e cópia dos dados para o aparelho
    page.goto(f'{BASE}/login')
    page.get_by_label('E-mail').fill('almox.mur@teste.local')
    page.get_by_label('Senha').fill('teste123')
    page.get_by_role('button', name='Entrar').click()
    page.wait_for_url(re.compile(r'.*/$'), timeout=15000)
    page.goto(f'{BASE}/saidas-offline')
    page.get_by_role('button', name='Atualizar agora').click()
    expect(page.get_by_text(re.compile(r'Atualizado em'))).to_be_visible(timeout=60000)
    # app guardado pelo service worker
    page.wait_for_function("navigator.serviceWorker && navigator.serviceWorker.controller !== null || (location.reload(), false)", timeout=30000)
    page.wait_for_function("caches.match('/__build').then(r => !!r)", polling=500, timeout=60000)

    # SEM internet: reabre o app e registra a saída
    ctx.set_offline(True)
    page.goto(f'{BASE}/nova-saida')
    page.wait_for_timeout(3000)
    page.screenshot(path=f'{OUT}/o0_offline_aberto.png', full_page=True)
    for _ in range(3):
        if page.get_by_label('Código do QR Code ou do material').count():
            break
        page.get_by_role('button', name='Digitar código').click()
        page.wait_for_timeout(1500)
    page.screenshot(path=f'{OUT}/o0b_digitar.png', full_page=True)
    page.get_by_label('Código do QR Code ou do material').fill('MAT-DEMO000001')
    page.get_by_role('button', name='Buscar').click()
    expect(page.get_by_text('Material identificado')).to_be_visible(timeout=10000)
    page.get_by_role('textbox', name='Quantidade solicitada', exact=True).fill('3')
    page.get_by_role('textbox', name='Quantidade atendida', exact=True).fill('3')
    page.get_by_role('button', name='Adicionar à ME').click()
    page.wait_for_timeout(500)
    page.get_by_role('button', name=re.compile(r'^Continuar \(1 ite')).click()
    expect(page.get_by_text(re.compile('DEMO-CT-001 – Coleta domiciliar'))).to_be_visible()  # contrato fixo
    page.get_by_label('Setor').select_option(label='Manutenção mecânica')
    page.get_by_label('Ativo fixo (AF)').fill('DEMO-AF-0101')
    page.get_by_role('button', name='Continuar', exact=True).click()
    page.get_by_label('Pesquisar funcionário requisitante').fill('José')
    page.get_by_role('button', name=re.compile('José Carlos da Silva')).click()
    page.get_by_role('button', name='Ir para assinatura').click()
    canvas = page.locator('canvas')
    canvas.scroll_into_view_if_needed()
    page.evaluate("window.scrollBy(0, 120)")
    box = canvas.bounding_box()
    y0 = box['y'] + 50
    page.mouse.move(box['x'] + 30, y0)
    page.mouse.down()
    for i in range(1, 60):
        page.mouse.move(box['x'] + 30 + i * 5, y0 + (25 if i % 8 < 4 else -15))
    page.mouse.up()
    page.screenshot(path=f'{OUT}/o0c_assinatura.png', full_page=False)
    page.get_by_role('button', name='Confirmar assinatura').click()
    expect(page.get_by_text('A saída será guardada neste aparelho')).to_be_visible(timeout=10000)
    page.screenshot(path=f'{OUT}/o1_revisao_offline.png', full_page=True)
    page.get_by_role('button', name='Guardar no aparelho').click()
    expect(page.get_by_text('Saída guardada no aparelho').first).to_be_visible(timeout=10000)
    expect(page.get_by_text(re.compile(r'1 saída\(s\) guardada\(s\) no aparelho'))).to_be_visible()
    page.screenshot(path=f'{OUT}/o2_guardada.png', full_page=True)
    assert int(sql("select count(*) from stock_movements where entry_channel = 'offline'") or 0) == antes, 'enviou sem internet?'

    # Internet volta: envio automático
    ctx.set_offline(False)
    expect(page.get_by_text(re.compile(r'Saída registrada sem internet enviada: ME-'))).to_be_visible(timeout=60000)
    page.screenshot(path=f'{OUT}/o3_enviada.png', full_page=True)
    depois = int(sql("select count(*) from stock_movements where entry_channel = 'offline'") or 0)
    assert depois == antes + 1, f'ME offline não chegou ao banco ({antes} -> {depois})'
    print('ME offline:', sql("select me_number || ' ' || status || ' assinaturas=' || (select count(*) from signatures s where s.movement_id = m.id) from stock_movements m where entry_channel = 'offline' order by created_at desc limit 1"))
    print('OK')
    browser.close()
